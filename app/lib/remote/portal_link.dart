import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_portal/dsh_portal.dart';

import '../dev/remote_benchmark.dart';
import '../state/hosts_state.dart';
import 'link_status.dart';
import 'portal_device_info.dart';
import 'secret_store.dart';

class PortalHostLink extends HostLink {
  PortalHostLink(this.config, this.secrets, {Stream<void>? kicks, Future<PortalDeviceInfo> Function()? deviceInfo})
    : _deviceInfo = deviceInfo ?? PortalDeviceIdentity.instance.deviceInfo {
    _kicks = kicks?.listen((_) => kick());
  }
  final PortalHostConfig config;
  final SecretStore secrets;
  final Future<PortalDeviceInfo> Function() _deviceInfo;
  final _retryDelay = InterruptibleDelay();
  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  StreamSubscription<void>? _kicks;
  StreamSubscription<DshConnectionState>? _states;
  StreamSubscription<void>? _expiry;
  PortalSession? _session;
  DshClient? _client;
  Future<DshClient>? _opening;
  Future<void>? _recovery;
  DateTime? _lastPasswordLogin;
  bool _closed = false;
  HostLinkStatus _status = HostLinkStatus.idle;
  @override
  HostLinkStatus get status => _status;
  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;
  @override
  DshClient? get currentClient => _status.phase == HostLinkPhase.connected ? _client : null;
  @override
  Stream<DshClient> get clients => _clients.stream;

  void _set(HostLinkStatus value) {
    if (_closed) return;
    _status = value;
    _statuses.add(value);
  }

  static const _signIn = HostLinkError(HostLinkErrorKind.authFailed, 'Sign in again. / 请重新登录。');
  static const _unreachable = HostLinkError(HostLinkErrorKind.unreachable, 'Connection failed. Retry. / 连接失败，请重试。');

  @override
  Future<DshClient> open() => _opening ??= _open();
  Future<DshClient> _open() async {
    RemoteBenchmark.start('connect');
    _set(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    try {
      var session = _newSession();
      final stored = await secrets.read(config.cookieKey);
      _ensureOpen();
      try {
        session.restoreCookies(stored);
      } on FormatException {
        await secrets.delete(config.cookieKey);
      }
      if (session.hasCookies) {
        try {
          final client = await _connect(session);
          RemoteBenchmark.finish('connect');
          return client;
        } on DshHttpException catch (error) {
          if (!error.isUnauthorized) rethrow;
          _set(const HostLinkStatus(HostLinkPhase.reconnecting, step: HostLinkStep.login));
          await _disconnect();
          _ensureOpen();
          session = _newSession();
        }
      }
      await _authenticate(session);
      final client = await _connect(session);
      RemoteBenchmark.finish('connect');
      return client;
    } on Object catch (error) {
      RemoteBenchmark.cancel('connect');
      await _disconnect();
      if (_closed) rethrow;
      final failure = error is HostLinkError ? error : _unreachable;
      _set(HostLinkStatus(HostLinkPhase.failed, error: failure));
      throw failure;
    }
  }

  PortalSession _newSession() => _session = PortalSession(
    config.base,
    saveCookies: (value) {
      if (_closed) return Future.value();
      return value == null ? secrets.delete(config.cookieKey) : secrets.write(config.cookieKey, value);
    },
  );

  void _ensureOpen() {
    if (_closed) throw const DshClosedException();
  }

  Future<void> _authenticate(PortalSession session) async {
    final password = await secrets.read(config.passwordKey);
    _ensureOpen();
    if (password == null) throw _signIn;
    final deviceInfo = await _deviceInfo();
    final backoff = Backoff(initial: const Duration(seconds: 2), maxAttempts: null);
    var passwordPosts = 0;
    while (true) {
      _ensureOpen();
      final lastLogin = _lastPasswordLogin;
      if (lastLogin != null) {
        final nextLogin = lastLogin.add(const Duration(seconds: 30));
        final remaining = nextLogin.difference(DateTime.now());
        if (remaining > Duration.zero) {
          await _retryDelay.wait(remaining);
          continue;
        }
      }
      try {
        final health = await session.connection.get(
          '/__portal/health',
          timeout: const Duration(seconds: 5),
          followRedirects: false,
          maxResponseBytes: 16384,
        );
        _ensureOpen();
        if (health.statusCode != 200) throw DshHttpException(health.statusCode, 'Portal unavailable');
        passwordPosts++;
        await session.login(password, deviceInfo: deviceInfo);
        _ensureOpen();
        _lastPasswordLogin = DateTime.now();
        return;
      } on PortalInvalidPasswordException {
        if (await secrets.read(config.passwordKey) == password && !_closed) {
          await secrets.delete(config.passwordKey);
        }
        throw _signIn;
      } on DshHttpException catch (error) {
        if (error.statusCode < 500) rethrow;
      } on DshTransportException {
        // Probe again before retrying a password POST whose response was lost.
      }
      _ensureOpen();
      if (passwordPosts >= 3) throw _unreachable;
      final delay = backoff.next();
      _set(
        HostLinkStatus(
          HostLinkPhase.reconnecting,
          step: HostLinkStep.connect,
          attempt: backoff.attempt,
          nextRetryAt: DateTime.now().add(delay),
        ),
      );
      await _retryDelay.wait(delay);
    }
  }

  Future<DshClient> _connect(PortalSession session) async {
    final client = _client = DshClient(session.connection);
    var ready = false;
    _expiry = session.expired.listen((_) {
      if (!ready || _closed || !identical(_session, session)) return;
      // The expiry callback runs synchronously from the rejected HTTP request.
      _recovery ??= Future<void>.microtask(_recover).whenComplete(() => _recovery = null);
    });
    _states = client.mux.states.listen((value) {
      if (!identical(_client, client) || !identical(_session, session)) return;
      switch (value) {
        case DshConnectionState.connected:
          if (ready) _set(const HostLinkStatus(HostLinkPhase.connected));
        case DshConnectionState.reconnecting:
          _set(const HostLinkStatus(HostLinkPhase.reconnecting));
        case DshConnectionState.unauthorized:
          if (client.mux.lastError case DshHttpException(isUnauthorized: true)) break;
          _set(const HostLinkStatus(HostLinkPhase.failed, error: _unreachable));
        default:
          break;
      }
    });
    await client.mux.ready();
    _ensureOpen();
    ready = true;
    _set(const HostLinkStatus(HostLinkPhase.connected));
    return client;
  }

  Future<void> _recover() async {
    if (_closed) return;
    _set(const HostLinkStatus(HostLinkPhase.reconnecting, step: HostLinkStep.login));
    try {
      await _disconnect();
      _ensureOpen();
      final session = _newSession();
      await _authenticate(session);
      final client = await _connect(session);
      if (!_closed) _clients.add(client);
    } on Object catch (error) {
      await _disconnect();
      final failure = error is HostLinkError ? error : _unreachable;
      _set(HostLinkStatus(HostLinkPhase.failed, error: failure));
    }
  }

  Future<void> _disconnect() async {
    final states = _states;
    final expiry = _expiry;
    final client = _client;
    final session = _session;
    _states = null;
    _expiry = null;
    _client = null;
    _session = null;
    await states?.cancel();
    await expiry?.cancel();
    await client?.close();
    await session?.close();
  }

  @override
  void kick() {
    if (!_closed && _status.phase == HostLinkPhase.reconnecting) {
      _retryDelay.skip();
      _client?.mux.reconnect();
    }
  }

  @override
  void retry() {
    _retryDelay.skip();
    _client?.mux.reconnect();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retryDelay.cancel();
    await _kicks?.cancel();
    await _disconnect();
    await _statuses.close();
    await _clients.close();
  }
}
