import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_info.dart';

int compareVersions(String left, String right) {
  List<String> parse(String value) {
    final match = RegExp(r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')
        .firstMatch(value);
    if (match == null) throw FormatException('Invalid version', value);
    return [match[1]!, match[2]!, match[3]!, match[4] ?? ''];
  }

  final a = parse(left);
  final b = parse(right);
  for (var i = 0; i < 3; i++) {
    final order = int.parse(a[i]).compareTo(int.parse(b[i]));
    if (order != 0) return order;
  }
  if (a[3].isEmpty || b[3].isEmpty) return a[3].isEmpty ? (b[3].isEmpty ? 0 : 1) : -1;
  final ap = a[3].split('.');
  final bp = b[3].split('.');
  for (var i = 0; i < ap.length && i < bp.length; i++) {
    final an = int.tryParse(ap[i]);
    final bn = int.tryParse(bp[i]);
    final order = an != null && bn != null
        ? an.compareTo(bn)
        : an != null
        ? -1
        : bn != null
        ? 1
        : ap[i].compareTo(bp[i]);
    if (order != 0) return order;
  }
  return ap.length.compareTo(bp.length);
}

class AppRelease {
  AppRelease.fromJson(Map<String, dynamic> json)
    : version = (json['tag_name'] as String).replaceFirst(RegExp(r'^v'), ''),
      notes = json['body'] as String? ?? '',
      page = Uri.parse(json['html_url'] as String),
      assets = (json['assets'] as List? ?? []).cast<Map<String, dynamic>>();

  final String version;
  final String notes;
  final Uri page;
  final List<Map<String, dynamic>> assets;

  Uri downloadUrl(String platform) {
    final extension = switch (platform) {
      'android' => '.apk',
      'ios' => '.ipa',
      _ => null,
    };
    if (extension == null) return page;
    final matching = assets
        .where((asset) => (asset['name'] as String? ?? '').toLowerCase().endsWith(extension))
        .toList();
    if (platform == 'android') {
      final arm64 = matching.where((asset) => (asset['name'] as String).toLowerCase().contains('arm64'));
      if (arm64.isNotEmpty) return Uri.parse(arm64.first['browser_download_url'] as String);
    }
    return matching.isEmpty ? page : Uri.parse(matching.first['browser_download_url'] as String);
  }
}

class ReleaseChecker {
  ReleaseChecker({this.client, this.version = AppInfo.version, DateTime Function()? now}) : now = now ?? DateTime.now;

  static final instance = ReleaseChecker();
  static final endpoint = Uri.parse('https://api.github.com/repos/tsukii12/dsh-YuRemote/releases/latest');
  static const lastCheckKey = 'release_last_check';
  static const skippedKey = 'release_skipped_version';
  final http.Client? client;
  final String version;
  final DateTime Function() now;
  Future<AppRelease?>? _active;

  Future<AppRelease?> check({bool automatic = false}) {
    final active = _active;
    if (active != null) return automatic ? Future.value() : active.then((_) => check());
    final request = _check(automatic: automatic);
    _active = request;
    return request.whenComplete(() => _active = null);
  }

  Future<AppRelease?> _check({required bool automatic}) async {
    http.Client? owned;
    try {
      final prefs = await SharedPreferences.getInstance();
      final time = now().millisecondsSinceEpoch;
      final last = prefs.getInt(lastCheckKey);
      if (automatic && last != null && time - last < const Duration(hours: 24).inMilliseconds) return null;
      await prefs.setInt(lastCheckKey, time);
      final response = await (client ?? (owned = http.Client()))
          .get(endpoint, headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'YuRemote'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) throw http.ClientException('Release check failed (${response.statusCode})');
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['draft'] == true || json['prerelease'] == true) return null;
      final release = AppRelease.fromJson(json);
      if (compareVersions(release.version, version) <= 0) return null;
      if (automatic && prefs.getString(skippedKey) == release.version) return null;
      return release;
    } finally {
      owned?.close();
    }
  }

  Future<void> skip(AppRelease release) async {
    await (await SharedPreferences.getInstance()).setString(skippedKey, release.version);
  }
}
