import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dsh_portal/dsh_portal.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_info.dart';

class PortalDeviceIdentity {
  static final instance = PortalDeviceIdentity();
  static const _key = 'portal_installation_client_id';
  Future<String>? _clientId;

  Future<String> clientId() => _clientId ??= _loadClientId();

  Future<String> _loadClientId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null && RegExp(r'^[A-Za-z0-9_-]{8,80}$').hasMatch(saved)) return saved;
    final random = Random.secure();
    final id = base64UrlEncode(List.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
    if (!await prefs.setString(_key, id)) throw StateError('Could not save device identity.');
    return id;
  }

  Future<PortalDeviceInfo> deviceInfo() async {
    final id = await clientId();
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final platform = isIos ? 'iOS' : 'Android';
    var name = '$platform device';
    var version = Platform.operatingSystemVersion;
    try {
      final plugin = DeviceInfoPlugin();
      if (isIos) {
        final info = await plugin.iosInfo;
        name = info.name.trim().isNotEmpty ? info.name : info.model;
        version = info.systemVersion;
      } else {
        final info = await plugin.androidInfo;
        name = info.model;
        version = info.version.release;
      }
    } on Object {
      // Login still works if the platform metadata is unavailable.
    }
    return PortalDeviceInfo(
      clientId: id,
      deviceName: name,
      platform: platform,
      osVersion: version,
      appVersion: AppInfo.version,
    );
  }
}
