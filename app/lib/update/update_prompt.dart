import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../state/app_info.dart';
import '../state/hosts_state.dart';
import '../ui/chat/render/markdown_body.dart';
import '../ui/settings/settings_widgets.dart';
import 'release_check.dart';
import 'apk_download_dialog.dart';

enum UpdateAction { download, later, skip }

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.release});

  final AppRelease release;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text('${l10n.updateAvailable} · ${release.version}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: MarkdownBody(text: release.notes.isEmpty ? l10n.updateNoNotes : release.notes),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, UpdateAction.skip), child: Text(l10n.updateSkip)),
        TextButton(onPressed: () => Navigator.pop(context, UpdateAction.later), child: Text(l10n.updateLater)),
        FilledButton(onPressed: () => Navigator.pop(context, UpdateAction.download), child: Text(l10n.updateDownload)),
      ],
    );
  }
}

Future<void> showUpdatePrompt(BuildContext context, AppRelease release, ReleaseChecker checker) async {
  final action = await showDialog<UpdateAction>(
    context: context,
    builder: (_) => UpdateDialog(release: release),
  );
  if (action == UpdateAction.skip) await checker.skip(release);
  if (action != UpdateAction.download || !context.mounted) return;
  try {
    final url = release.downloadUrl(Platform.operatingSystem);
    if (Platform.isAndroid && url.path.toLowerCase().endsWith('.apk')) {
      final fallback = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ApkDownloadDialog(url: url),
      );
      if (fallback != true || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.updateDownloadFallback)));
    }
    if (url.scheme == 'https' && await launchUrl(url, mode: LaunchMode.externalApplication)) return;
  } on Object {
    // The platform can refuse an otherwise valid URL.
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.stateBrowserOpenFailed)));
  }
}

class UpdateCheckTile extends StatefulWidget {
  const UpdateCheckTile({super.key, this.checker});

  final ReleaseChecker? checker;

  @override
  State<UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends State<UpdateCheckTile> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final checker = widget.checker ?? ReleaseChecker.instance;
    try {
      final release = await checker.check();
      if (!mounted) return;
      if (release != null) {
        await showUpdatePrompt(context, release, checker);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.updateCurrent)));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.updateFailed)));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsTile(
    spot: Spots.version,
    title: context.l10n.updateCheck,
    value: Text(AppInfo.displayVersion),
    trailing: _checking ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
    onTap: _checking ? null : _check,
  );
}

/// The version whose notes were last shown. A launch with no record counts as
/// an update when the app was already set up (a saved host), so a fresh
/// install stays quiet.
const whatsNewSeenKey = 'whats_new_seen_version';

Future<bool> firstLaunchAfterUpdate() async {
  final prefs = await SharedPreferences.getInstance();
  final seen = prefs.getString(whatsNewSeenKey);
  if (seen == AppInfo.version) return false;
  await prefs.setString(whatsNewSeenKey, AppInfo.version);
  return seen != null || prefs.containsKey(HostsController.prefsKey);
}

class WhatsNewDialog extends StatelessWidget {
  const WhatsNewDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text('${l10n.updateWhatsNew} · ${AppInfo.version.split('+').first}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(child: MarkdownBody(text: l10n.updateWhatsNewNotes)),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(l10n.updateWhatsNewOk))],
    );
  }
}

class StartupUpdateCheck extends StatefulWidget {
  const StartupUpdateCheck({super.key, required this.child});

  final Widget child;

  @override
  State<StartupUpdateCheck> createState() => _StartupUpdateCheckState();
}

class _StartupUpdateCheckState extends State<StartupUpdateCheck> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    try {
      if (await firstLaunchAfterUpdate() && mounted) {
        await showDialog<void>(context: context, builder: (_) => const WhatsNewDialog());
      }
    } on Object {
      // A preference failure only skips the notes.
    }
    if (!mounted) return;
    try {
      final checker = ReleaseChecker.instance;
      final release = await checker.check(automatic: true);
      if (release != null && mounted) await showUpdatePrompt(context, release, checker);
    } on Object {
      // Automatic checks never surface network or preference failures.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
