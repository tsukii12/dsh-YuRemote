import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _Folder = ({String parent, Map<String, String> children});

class _FolderConnection extends DshConnection {
  _FolderConnection({
    required this.home,
    required this.roots,
    this.folders = const {},
  }) : super(Uri.parse('http://fixture.invalid'));

  final String home;
  final List<String> roots;
  final Map<String, _Folder> folders;
  final requests = <String?>[];

  @override
  Future<DshHttpResponse> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
  }) async {
    expect(path, '/yuremote/fs');
    final requested = query?['path'];
    requests.add(requested);
    final current = requested ?? home;
    final folder = folders[current];
    final data = {
      'ok': true,
      'listing': {
        'path': current,
        'parent': folder?.parent ?? '',
        'roots': [
          {'name': '~ $home', 'path': home},
          for (final root in roots) {'name': root, 'path': root},
        ],
        'entries': [
          for (final child in (folder?.children ?? const {}).entries)
            {'name': child.key, 'path': child.value},
        ],
      },
    };
    return DshHttpResponse(
      200,
      'application/json',
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openPicker(
    WidgetTester tester,
    _FolderConnection connection,
  ) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = DshClient(connection);
    addTearDown(client.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData(HostConnection(client: client)),
          ),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDirectoryPicker(
                  context,
                  title: appL10n.remoteWorkspaceAdd,
                ),
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'drives are listed directly below home and open at the selected drive root',
    (tester) async {
      final connection = _FolderConnection(
        home: r'C:\Users\Demo',
        roots: const [r'C:\', r'D:\'],
        folders: const {
          r'D:\': (parent: '', children: {'Projects': r'D:\Projects'}),
          r'D:\Projects': (
            parent: r'D:\',
            children: {'Sample': r'D:\Projects\Sample'},
          ),
          r'D:\Projects\Sample': (parent: r'D:\Projects', children: {}),
        },
      );
      await openPicker(tester, connection);
      final home = find.text(appL10n.remoteDirectoryHome);
      final c = find.text(r'C:\');
      final d = find.text(r'D:\');
      expect(home, findsOneWidget);
      expect(find.text(r'~ C:\Users\Demo'), findsNothing);
      expect(tester.getTopLeft(home).dy, lessThan(tester.getTopLeft(c).dy));
      expect(tester.getTopLeft(c).dy, lessThan(tester.getTopLeft(d).dy));

      await tapRow(tester, r'D:\');
      expect(connection.requests, [null, r'D:\']);
      await tapRow(tester, 'Projects');
      await tapRow(tester, 'Sample');
      expect(connection.requests.last, r'D:\Projects\Sample');
      await tapRow(tester, appL10n.portalDirectoryParent);
      expect(connection.requests.last, r'D:\Projects');
      expect(find.byType(DirectoryBrowserPage), findsOneWidget);
      await tapRow(tester, 'Sample');

      final beforeBack = connection.requests.length;
      await tester.tap(find.byTooltip(appL10n.commonBack));
      await tester.pumpAndSettle();
      expect(find.byType(DirectoryBrowserPage), findsNothing);
      expect(find.byType(DirectoryLocationsSheet), findsOneWidget);
      expect(connection.requests, hasLength(beforeBack));

      await tapRow(tester, r'D:\');
      await tapRow(tester, 'Projects');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DirectoryBrowserPage), findsNothing);
      expect(find.byType(DirectoryLocationsSheet), findsOneWidget);
    },
  );

  testWidgets('a non-Windows host can offer its filesystem root', (
    tester,
  ) async {
    final connection = _FolderConnection(
      home: '/home/demo',
      roots: const ['/'],
    );
    await openPicker(tester, connection);
    expect(find.text(appL10n.remoteDirectoryHome), findsOneWidget);
    await tapRow(tester, '/');
    expect(connection.requests, [null, '/']);
  });

  testWidgets('no drive rows are fabricated when the host reports only home', (
    tester,
  ) async {
    await openPicker(
      tester,
      _FolderConnection(home: '/home/demo', roots: const []),
    );
    expect(find.text(appL10n.remoteDirectoryHome), findsOneWidget);
    expect(find.text('~'), findsOneWidget);
    expect(find.text('~ /home/demo'), findsNothing);
    expect(find.text('/'), findsNothing);
    expect(find.text(r'C:\'), findsNothing);
  });
}
