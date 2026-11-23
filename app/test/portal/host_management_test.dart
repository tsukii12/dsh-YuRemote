import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/host_actions.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final host = PortalHostConfig(id: 'demo', name: 'Demo host', base: Uri.parse('https://example.test/'));
  final l10n = lookupL10n(const Locale('en'));

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    required Widget home,
    List<PortalHostConfig> hosts = const [],
    MemorySecretStore? secrets,
    GlobalKey<NavigatorState>? navigator,
  }) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode(hosts.map((h) => h.toJson()).toList()),
      if (hosts.isNotEmpty) ActiveHostController.prefsKey: HostRef.portal(hosts.first.id).encode(),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secretStoreProvider.overrideWithValue(secrets ?? MemorySecretStore())],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: buildLightTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('en'),
          home: home,
        ),
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byWidget(home)));
    container.read(activeHostProvider);
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('a QR scan leaves the name blank and cannot submit without one', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await pumpApp(tester, home: const RemoteScreen(), navigator: nav);
    final name = find.byKey(const ValueKey('portal-name'));
    await tester.enterText(name, 'A name from before the scan');
    await tester.tap(find.byTooltip(l10n.portalScan));
    nav.currentState!.pop('https://example.test/__portal/pair?t=demo-token');
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(name).controller!.text, isEmpty);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('portal-url'))).controller!.text, '${host.base}');
    expect(find.text(l10n.portalPairingReady), findsOneWidget);
    await tester.tap(find.text(l10n.commonSignIn));
    await tester.pumpAndSettle();
    expect(find.text(l10n.portalNameRequired), findsOneWidget);
  });

  testWidgets('host management edits the name without changing saved credentials or selection', (tester) async {
    final secrets = MemorySecretStore({host.cookieKey: 'fixture'});
    final container = await pumpApp(tester, home: const RemoteScreen(), hosts: [host], secrets: secrets);
    await tester.tap(find.byType(PopupMenuButton<HostAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.commonEdit));
    await tester.pumpAndSettle();
    expect(find.text(host.name), findsNWidgets(2));

    await tester.enterText(find.byType(TextFormField), '  ');
    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();
    expect(find.text(l10n.portalNameRequired), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), ' Renamed host ');
    await tester.tap(find.text(l10n.commonSave));
    await tester.pumpAndSettle();
    expect(find.text('Renamed host'), findsOneWidget);
    expect(container.read(activeHostProvider).id, host.id);
    expect(container.read(hostsProvider).portals.single.base, host.base);
    expect(secrets.values, {host.cookieKey: 'fixture'});
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(HostsController.prefsKey)!), [
      {...host.toJson(), 'name': 'Renamed host'},
    ]);
  });

  testWidgets('sidebar long-press offers edit and confirmed deletion of the active host', (tester) async {
    final secrets = MemorySecretStore({host.cookieKey: 'fixture'});
    final container = await pumpApp(
      tester,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHostSheet(context, onManage: () {}),
            child: const Text('Open switcher'),
          ),
        ),
      ),
      hosts: [host],
      secrets: secrets,
    );
    await tester.tap(find.text('Open switcher'));
    await tester.pumpAndSettle();

    Future<void> openDelete() async {
      await tester.longPress(find.text(host.name));
      await tester.pumpAndSettle();
      expect(find.text(l10n.commonEdit), findsOneWidget);
      await tester.tap(find.text(l10n.commonDelete));
      await tester.pumpAndSettle();
      expect(find.text(l10n.portalDeleteHostConfirmation(host.name)), findsOneWidget);
    }

    await openDelete();
    await tester.tap(find.text(l10n.commonCancel));
    await tester.pumpAndSettle();
    expect(container.read(hostsProvider).portals.single.toJson(), host.toJson());

    await openDelete();
    await tester.tap(find.text(l10n.commonDelete));
    await tester.pumpAndSettle();
    expect(find.byType(HostSheet), findsNothing);
    expect(container.read(hostsProvider).portals, isEmpty);
    expect(container.read(activeHostProvider), HostRef.none);
    expect(secrets.values, isEmpty);
  });
}
