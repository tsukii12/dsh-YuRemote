import 'package:dsh_portal/dsh_portal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/portal_device_info.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'host_actions.dart';
import 'pairing_page.dart';

class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key, this.host});
  final PortalHostConfig? host;
  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  String? _token;
  String? _error;
  bool _scanned = false;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _url.text = widget.host?.base.toString() ?? '';
    _name.text = widget.host?.name ?? '';
  }

  @override
  void didUpdateWidget(covariant RemoteScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.host;
    final current = widget.host;
    if (previous != null &&
        current != null &&
        previous.id == current.id &&
        previous.name != current.name &&
        _name.text == previous.name) {
      _name.text = current.name;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    _password.dispose();
    _token = null;
    super.dispose();
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const RemotePairingPage()));
    if (result == null || !mounted) return;
    try {
      final scan = PortalScan.parse(result);
      setState(() {
        _url.text = scan.base.toString();
        _name.clear();
        _scanned = true;
        _token = scan.token;
        _password.clear();
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _login() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (_scanned && name.isEmpty) {
      setState(() => _error = context.l10n.portalNameRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    PortalSession? session;
    try {
      final base = normalizePortalUrl(_url.text);
      final hosts = ref.read(hostsProvider).portals;
      final existing = hosts.where((h) => h.base == base).firstOrNull;
      final config = PortalHostConfig(
        id: existing?.id ?? base.toString(),
        name: name.isEmpty ? base.host : name,
        base: base,
      );
      final secrets = ref.read(secretStoreProvider);
      session = PortalSession(
        base,
        saveCookies: (value) =>
            value == null ? secrets.delete(config.cookieKey) : secrets.write(config.cookieKey, value),
      );
      final deviceInfo = await PortalDeviceIdentity.instance.deviceInfo();
      final token = _token;
      final password = _password.text;
      await session.login(token ?? password, pairing: token != null, deviceInfo: deviceInfo);
      if (token == null) await secrets.write(config.passwordKey, password);
      if (!mounted) return;
      _password.clear();
      _token = null;
      _scanned = false;
      await ref.read(hostsProvider.notifier).save(config);
      if (!mounted) return;
      final host = HostRef.portal(config.id, name: config.name);
      ref.invalidate(hostLinkProvider(host));
      ref.read(activeHostProvider.notifier).select(host);
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    } on PortalInvalidPasswordException {
      if (mounted) setState(() => _error = context.l10n.portalInvalidPassword);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error is FormatException ? error.message : error.toString());
    } finally {
      await session?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hosts = ref.watch(hostsProvider).portals;
    return AppPage.list(
      title: l10n.commonRemoteHost,
      subtitle: Text(l10n.portalRemoteOnly),
      actions: [
        IconButton(tooltip: l10n.portalScan, onPressed: _busy ? null : _scan, icon: const Icon(Icons.qr_code_scanner)),
      ],
      children: [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: BrandMark(size: 64, tile: true)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GlassSurface(
            tier: GlassTier.card,
            padding: const EdgeInsets.all(20),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('portal-url'),
                    controller: _url,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onChanged: (_) {
                      if (_token != null) setState(() => _token = null);
                    },
                    decoration: InputDecoration(labelText: l10n.portalAddress, hintText: 'https://host:8443/__t/id/'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('portal-name'),
                    controller: _name,
                    enabled: !_busy,
                    decoration: InputDecoration(labelText: l10n.portalName),
                  ),
                  const SizedBox(height: 12),
                  if (_token != null)
                    Text(l10n.portalPairingReady)
                  else
                    TextField(
                      key: const ValueKey('portal-password'),
                      controller: _password,
                      enabled: !_busy,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _login(),
                      decoration: InputDecoration(labelText: l10n.portalPassword),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _login,
                    child: _busy
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l10n.commonSignIn),
                  ),
                ],
              ),
            ),
          ),
        ),
        for (final host in hosts)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const Icon(Icons.dns_outlined),
            title: Text(host.name),
            subtitle: Text(host.base.toString()),
            trailing: PopupMenuButton<HostAction>(
              enabled: !_busy,
              onSelected: (action) => runHostAction(context, ref, host, action),
              itemBuilder: (context) => [
                for (final action in HostAction.values)
                  PopupMenuItem(value: action, child: Text(action.label(context.l10n))),
              ],
            ),
            onTap: _busy
                ? null
                : () {
                    ref.read(activeHostProvider.notifier).select(HostRef.portal(host.id, name: host.name));
                    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
                  },
          ),
      ],
    );
  }
}
