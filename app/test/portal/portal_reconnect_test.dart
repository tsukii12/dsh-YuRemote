import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/portal_link.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_portal/dsh_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portal link and a late sidebar subscriber recover after relay socket loss', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    var generation = 0;
    server.listen((request) async {
      expect(request.uri.path, '/__t/test/api/remote.mux');
      expect(request.headers.value(HttpHeaders.cookieHeader), 'fixture=local');
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((data) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        if (frame['type'] == 'open' && frame['endpoint'] == r'$events') {
          socket.add(
            jsonEncode({
              'type': 'item',
              'streamId': frame['streamId'],
              'value': {
                'type': 'ready',
                'clientId': 'relay-${++generation}',
                'host': {'home': '/home/test'},
              },
            }),
          );
        }
      });
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}/__t/test/');
    final config = PortalHostConfig(id: 'relay', name: 'Relay', base: base);
    final secrets = MemorySecretStore({
      config.cookieKey: jsonEncode({
        'base': base.toString(),
        'cookies': ['fixture=local; Path=/__t/test/'],
      }),
    });
    final link = PortalHostLink(config, secrets);
    final container = ProviderContainer(
      overrides: [hostLinkProvider(const HostRef.portal('relay')).overrideWithValue(link)],
    );
    addTearDown(() async {
      container.dispose();
      await link.close();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    final initial = link.statuses.firstWhere((value) => value.phase == HostLinkPhase.connected);
    final client = await link.open().timeout(const Duration(seconds: 10));
    await initial;
    final first = client.mux.generation;
    expect(link.currentClient, same(client));

    final lost = link.statuses.firstWhere((value) => value.phase == HostLinkPhase.reconnecting);
    await sockets.single.close(WebSocketStatus.goingAway, 'relay stopped');
    await lost.timeout(const Duration(seconds: 10));
    expect(link.currentClient, isNull);
    final recovered = link.statuses.firstWhere((value) => value.phase == HostLinkPhase.connected);
    await recovered.timeout(const Duration(seconds: 10));
    expect(link.currentClient, same(client));
    expect(client.mux.generation, isNot(same(first)));

    const host = HostRef.portal('relay');
    final subscription = container.listen(hostLinkStatusProvider(host), (_, _) {});
    addTearDown(subscription.close);
    expect((await container.read(hostLinkStatusProvider(host).future)).phase, HostLinkPhase.connected);
    expect(await link.open(), same(client));
  });

  test('a relay that rejects saved cookies fails the link with sign-in-again', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.statusCode = HttpStatus.unauthorized;
      unawaited(request.response.close());
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}/__t/test/');
    final config = PortalHostConfig(id: 'relay', name: 'Relay', base: base);
    final secrets = MemorySecretStore({
      config.cookieKey: jsonEncode({
        'base': base.toString(),
        'cookies': ['fixture=stale; Path=/__t/test/'],
      }),
    });
    final link = PortalHostLink(config, secrets);
    addTearDown(() async {
      await link.close();
      await server.close(force: true);
    });
    await expectLater(
      link.open().timeout(const Duration(seconds: 10)),
      throwsA(isA<HostLinkError>().having((e) => e.kind, 'kind', HostLinkErrorKind.authFailed)),
    );
    expect(link.status.error?.kind, HostLinkErrorKind.authFailed);
  });

  test('saved password connects without cookies, then reuses the cookies on next launch', () async {
    final portal = await _PortalFixture.start();
    var link = portal.link();
    expect(await link.open(), same(link.currentClient));
    expect(portal.posts, 1);
    expect(portal.secrets.values[portal.config.cookieKey], isNotNull);
    expect(portal.secrets.values[portal.config.passwordKey], _PortalFixture.password);
    await link.close();

    link = portal.link();
    expect(await link.open(), same(link.currentClient));
    expect(portal.posts, 1);
  });

  test('rejected startup cookies cause one silent password sign-in', () async {
    final portal = await _PortalFixture.start();
    await portal.secrets.write(
      portal.config.cookieKey,
      jsonEncode({
        'base': portal.config.base.toString(),
        'cookies': ['fixture=stale; Path=/__t/test/'],
      }),
    );
    final link = portal.link();
    final phases = <HostLinkPhase>[];
    final statuses = link.statuses.listen((status) => phases.add(status.phase));
    addTearDown(statuses.cancel);
    expect(await link.open(), same(link.currentClient));
    expect(portal.posts, 1);
    expect(phases, isNot(contains(HostLinkPhase.failed)));
  });

  test('live HTTP expiry replaces the active connection without showing sign-in', () async {
    final portal = await _PortalFixture.start();
    await portal.seedCookies('current');
    final link = portal.link();
    const host = HostRef.portal('relay');
    final container = ProviderContainer(overrides: [hostLinkProvider(host).overrideWithValue(link)]);
    addTearDown(container.dispose);
    final provider = remoteConnectionProvider(host);
    final replacement = Completer<DshClient>();
    final errors = <Object>[];
    DshClient? original;
    final subscription = container.listen(provider, (_, value) {
      if (value.error case final error?) errors.add(error);
      if (value.value?.client case final client?) {
        if (original != null && client != original && !replacement.isCompleted) replacement.complete(client);
      }
    });
    addTearDown(subscription.close);
    final current = (await container.read(provider.future))!.client;
    original = current;

    portal.validCookie = null;
    await expectLater(current.rpc.call('session/list'), throwsA(isA<DshHttpException>()));
    final client = await replacement.future.timeout(const Duration(seconds: 10));
    expect(client, same(link.currentClient));
    expect(errors, isEmpty);
    expect(portal.posts, 1);
    expect(portal.secrets.values[portal.config.passwordKey], _PortalFixture.password);
  });

  for (final (status, code, wrongPassword) in [
    (401, 'invalid-password', true),
    (401, 'password-mode-disabled', false),
    (429, 'locked', false),
  ]) {
    test('password POST $status / $code is not repeated', () async {
      final portal = await _PortalFixture.start();
      portal.loginError = (status, code);
      final link = portal.link();
      final kind = wrongPassword ? HostLinkErrorKind.authFailed : HostLinkErrorKind.unreachable;
      await expectLater(link.open(), throwsA(isA<HostLinkError>().having((e) => e.kind, 'kind', kind)));
      link.kick();
      await expectLater(link.open(), throwsA(isA<HostLinkError>()));
      expect(portal.posts, 1);
      expect(portal.secrets.values[portal.config.passwordKey], wrongPassword ? null : _PortalFixture.password);
    });
  }

  test('offline health retry does not post the password until the host responds', () async {
    final portal = await _PortalFixture.start();
    portal.healthStatus = HttpStatus.serviceUnavailable;
    final link = portal.link();
    final waiting = link.statuses.firstWhere((status) => status.nextRetryAt != null);
    final opening = link.open();
    await waiting.timeout(const Duration(seconds: 10));
    expect(portal.posts, 0);
    expect(portal.secrets.values[portal.config.passwordKey], _PortalFixture.password);

    portal.healthStatus = HttpStatus.ok;
    link.kick();
    await opening.timeout(const Duration(seconds: 10));
    expect(portal.posts, 1);
  });
}

class _PortalFixture {
  _PortalFixture(this.config) : secrets = MemorySecretStore({config.passwordKey: password});

  static const password = 'test 密码 + &';
  final PortalHostConfig config;
  final MemorySecretStore secrets;
  final sockets = <WebSocket>[];
  int healthStatus = HttpStatus.ok;
  (int, String)? loginError;
  String? validCookie;
  int posts = 0;

  static Future<_PortalFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = Uri.parse('http://127.0.0.1:${server.port}/__t/test/');
    final portal = _PortalFixture(PortalHostConfig(id: 'relay', name: 'Relay', base: base));
    server.listen(portal.handle);
    addTearDown(() async {
      for (final socket in portal.sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    return portal;
  }

  Future<void> seedCookies(String value) {
    validCookie = 'fixture=$value';
    return secrets.write(
      config.cookieKey,
      jsonEncode({
        'base': config.base.toString(),
        'cookies': ['$validCookie; Path=/__t/test/'],
      }),
    );
  }

  PortalHostLink link() {
    final link = PortalHostLink(
      config,
      secrets,
      deviceInfo: () async => const PortalDeviceInfo(
        clientId: 'test_device',
        deviceName: 'Test device',
        platform: 'Android',
        osVersion: '1',
        appVersion: '1',
      ),
    );
    addTearDown(link.close);
    return link;
  }

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path.endsWith('/__portal/health')) {
      expect(request.method, 'GET');
      response.statusCode = healthStatus;
    } else if (request.uri.path.endsWith('/__portal/login')) {
      expect(request.method, 'POST');
      final form = Uri.splitQueryString(await utf8.decoder.bind(request).join());
      expect(form['password'], password);
      expect(form['clientId'], 'test_device');
      expect(form, isNot(contains('token')));
      posts++;
      if (loginError case (final status, final code)) {
        response.statusCode = status;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'ok': false, 'code': code}));
      } else {
        validCookie = 'fixture=session-$posts';
        response.statusCode = HttpStatus.seeOther;
        response.headers.add(HttpHeaders.setCookieHeader, '$validCookie; Path=/__t/test/; HttpOnly');
      }
    } else if (validCookie == null || request.headers.value(HttpHeaders.cookieHeader) != validCookie) {
      response.statusCode = HttpStatus.unauthorized;
    } else {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((data) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        if (frame['type'] == 'open' && frame['endpoint'] == r'$events') {
          socket.add(
            jsonEncode({
              'type': 'item',
              'streamId': frame['streamId'],
              'value': {
                'type': 'ready',
                'clientId': 'relay-$posts',
                'host': {'home': '/home/test'},
              },
            }),
          );
        }
      });
      return;
    }
    await response.close();
  }
}
