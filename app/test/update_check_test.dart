import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/update/release_check.dart';
import 'package:dsh_app/update/update_prompt.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> releaseJson({
  List<Map<String, dynamic>> assets = const [],
  String notes = '## Changes\n\nA **better** app.',
}) => {
  'tag_name': 'v0.7.1',
  'html_url': 'https://github.com/tsukii12/dsh-YuRemote/releases/tag/v0.7.1',
  'body': notes,
  'assets': assets,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('what\'s new stays quiet on a fresh install and shows once after an update', () async {
    expect(await firstLaunchAfterUpdate(), isFalse);
    expect(await firstLaunchAfterUpdate(), isFalse);

    SharedPreferences.setMockInitialValues({whatsNewSeenKey: '0.7.0+1'});
    expect(await firstLaunchAfterUpdate(), isTrue);
    expect(await firstLaunchAfterUpdate(), isFalse);

    SharedPreferences.setMockInitialValues({HostsController.prefsKey: '[]'});
    expect(await firstLaunchAfterUpdate(), isTrue);
    expect(await firstLaunchAfterUpdate(), isFalse);
  });

  test('what\'s new shows once when upgrading from the original 0.8.1 build', () async {
    SharedPreferences.setMockInitialValues({whatsNewSeenKey: '0.8.1+29925484'});
    expect(await firstLaunchAfterUpdate(), isTrue);
    expect(await firstLaunchAfterUpdate(), isFalse);
  });

  test('semantic release, prerelease, numeric components and build metadata', () {
    final ordered = [
      '0.7.1-alpha',
      '0.7.1-alpha.2',
      '0.7.1-alpha.10',
      '0.7.1-beta',
      '0.7.1-dev',
      '0.7.1',
      '0.7.2',
      '0.10.0',
      '1.0.0',
    ];
    for (var i = 1; i < ordered.length; i++) {
      expect(compareVersions(ordered[i - 1], ordered[i]), lessThan(0));
      expect(compareVersions(ordered[i], ordered[i - 1]), greaterThan(0));
    }
    expect(compareVersions('v0.7.1+123', '0.7.1+456'), 0);
    expect(() => compareVersions('', '0.7.1'), throwsFormatException);
    expect(() => compareVersions('not-a-version', '0.7.1'), throwsFormatException);
  });

  test('asset selection prefers arm64 APK, uses IPA, falls back to release page', () {
    Map<String, dynamic> asset(String name) => {'name': name, 'browser_download_url': 'https://example.com/$name'};
    final release = AppRelease.fromJson(
      releaseJson(assets: [asset('app.apk'), asset('app-arm64.apk'), asset('app.ipa')]),
    );
    expect(release.downloadUrl('android').path, '/app-arm64.apk');
    expect(release.downloadUrl('ios').path, '/app.ipa');
    expect(release.downloadUrl('macos'), release.page);
    final generic = AppRelease.fromJson(releaseJson(assets: [asset('app.apk')]));
    expect(generic.downloadUrl('android').path, '/app.apk');
    expect(generic.downloadUrl('ios'), generic.page);
    final empty = AppRelease.fromJson(releaseJson());
    expect(empty.downloadUrl('android'), empty.page);
    expect(empty.downloadUrl('ios'), empty.page);
  });

  test('API request, daily persistence, skipped version, and manual override', () async {
    var requests = 0;
    var date = DateTime(2026, 1, 1);
    final client = MockClient((request) async {
      requests++;
      expect(request.url, ReleaseChecker.endpoint);
      expect(request.headers.containsKey('authorization'), isFalse);
      return http.Response(jsonEncode(releaseJson()), 200);
    });
    final checker = ReleaseChecker(client: client, version: '0.7.1-dev', now: () => date);
    final release = await checker.check(automatic: true);
    expect(release?.version, '0.7.1');
    await checker.skip(release!);
    expect(await ReleaseChecker(client: client, version: '0.7.0', now: () => date).check(automatic: true), isNull);
    expect(requests, 1);
    date = date.add(const Duration(hours: 24));
    expect(await checker.check(automatic: true), isNull);
    expect(requests, 2);
    expect(await checker.check(), isNotNull);
    expect(requests, 3);
  });

  test('current, older, missing, draft and prerelease releases do not prompt', () async {
    for (final version in ['0.7.1', '0.8.0']) {
      final checker = ReleaseChecker(
        version: version,
        client: MockClient((_) async => http.Response(jsonEncode(releaseJson()), 200)),
      );
      expect(await checker.check(), isNull);
    }
    for (final flag in ['draft', 'prerelease']) {
      final checker = ReleaseChecker(
        version: '0.1.0',
        client: MockClient((_) async => http.Response(jsonEncode({...releaseJson(), flag: true}), 200)),
      );
      expect(await checker.check(), isNull);
    }
    expect(await ReleaseChecker(client: MockClient((_) async => http.Response('', 404))).check(), isNull);
  });

  test('network, HTTP and malformed response errors propagate; failed auto checks are throttled', () async {
    for (final response in [http.Response('', 403), http.Response('not json', 200), http.Response('{}', 200)]) {
      final checker = ReleaseChecker(client: MockClient((_) async => response));
      await expectLater(checker.check(), throwsA(anything));
    }
    var requests = 0;
    final checker = ReleaseChecker(
      client: MockClient((_) async {
        requests++;
        throw http.ClientException('offline');
      }),
    );
    await expectLater(checker.check(), throwsA(isA<http.ClientException>()));
    expect(await checker.check(automatic: true), isNull);
    expect(requests, 1);
  });

  Widget app(Widget child) => ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(body: child),
    ),
  );

  testWidgets('dialog renders notes and each action returns its result', (tester) async {
    for (final entry in {'下载': UpdateAction.download, '以后': UpdateAction.later, '跳过此版本': UpdateAction.skip}.entries) {
      UpdateAction? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<UpdateAction>(
                  context: context,
                  builder: (_) => UpdateDialog(release: AppRelease.fromJson(releaseJson())),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 · 0.7.1'), findsOneWidget);
      expect(find.text('Changes'), findsOneWidget);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(result, entry.value);
    }
  });

  testWidgets('empty notes and long notes render without overflow', (tester) async {
    for (final notes in ['', List.filled(80, 'A release note.\n\n').join()]) {
      await tester.pumpWidget(app(UpdateDialog(release: AppRelease.fromJson(releaseJson(notes: notes)))));
      await tester.pumpAndSettle();
      expect(find.text('下载'), findsOneWidget);
      if (notes.isEmpty) expect(find.text('此版本暂无更新说明。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('manual entry shows spinner, current version result and errors', (tester) async {
    final response = Completer<http.Response>();
    await tester.pumpWidget(app(UpdateCheckTile(checker: ReleaseChecker(client: MockClient((_) => response.future)))));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    response.complete(http.Response(jsonEncode(releaseJson()..['tag_name'] = 'v0.1.0'), 200));
    await tester.pumpAndSettle();
    expect(find.text('已是最新版本'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      app(UpdateCheckTile(checker: ReleaseChecker(client: MockClient((_) async => http.Response('', 500))))),
    );
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('检查更新失败，请稍后重试。'), findsOneWidget);
  });
}
