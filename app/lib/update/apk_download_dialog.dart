import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../l10n/l10n.dart';
import 'apk_download.dart';

class ApkDownloadDialog extends StatefulWidget {
  const ApkDownloadDialog({super.key, required this.url, this.downloader, this.installer});

  final Uri url;
  final ApkDownloader? downloader;
  final ApkInstaller? installer;

  @override
  State<ApkDownloadDialog> createState() => _ApkDownloadDialogState();
}

class _ApkDownloadDialogState extends State<ApkDownloadDialog> {
  late final _downloader = widget.downloader ?? ApkDownloader();
  late final _installer = widget.installer ?? ApkInstaller();
  int _received = 0;
  int? _total;
  File? _file;
  bool _permissionDenied = false;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _download();
  }

  @override
  void dispose() {
    _downloader.cancel();
    super.dispose();
  }

  Future<void> _download() async {
    try {
      _file = await _downloader.download(widget.url, (received, total) {
        if (mounted) {
          setState(() {
            _received = received;
            _total = total;
          });
        }
      });
      if (mounted) await _install();
    } on DownloadCancelled {
      // Closing the dialog cancels without opening the browser.
    } on Object {
      if (mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _install() async {
    setState(() => _opening = true);
    try {
      final result = await _installer.open(_file!);
      if (!mounted) return;
      if (result == ResultType.permissionDenied) {
        setState(() => _permissionDenied = true);
      } else {
        Navigator.pop(context, result != ResultType.done);
      }
    } on Object {
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _settings() async {
    try {
      await _installer.openSettings();
    } on Object {
      if (mounted) Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final total = _total;
    final progress = total != null && total > 0 ? (_received / total).clamp(0.0, 1.0) : null;
    return AlertDialog(
      title: Text(_permissionDenied ? l10n.updateInstallPermissionTitle : l10n.updateDownloading),
      content: _permissionDenied
          ? Text(l10n.updateInstallPermissionBody)
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 12),
                Text(
                  progress == null ? '${(_received / 1048576).toStringAsFixed(1)} MB' : '${(progress * 100).floor()}%',
                ),
              ],
            ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.updateCancel)),
        if (_permissionDenied) ...[
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.updateBrowser)),
          TextButton(onPressed: _opening ? null : _settings, child: Text(l10n.updateOpenSettings)),
          FilledButton(onPressed: _opening ? null : _install, child: Text(l10n.updateInstallRetry)),
        ],
      ],
    );
  }
}
