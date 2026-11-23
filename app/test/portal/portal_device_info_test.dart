import 'package:dsh_app/remote/portal_device_info.dart';
import 'package:dsh_app/state/app_info.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/device_info');

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('client ID is random, URL safe and persisted across identity instances', () async {
    final identity = PortalDeviceIdentity();
    final ids = await Future.wait(List.generate(8, (_) => identity.clientId()));
    expect(ids.toSet(), hasLength(1));
    expect(ids.first, matches(RegExp(r'^[A-Za-z0-9_-]{8,80}$')));
    expect(await PortalDeviceIdentity().clientId(), ids.first);
    SharedPreferences.setMockInitialValues({});
    expect(await PortalDeviceIdentity().clientId(), isNot(ids.first));
  });

  test('invalid persisted ID is replaced and the replacement is persisted', () async {
    SharedPreferences.setMockInitialValues({'portal_installation_client_id': 'invalid value!'});
    final id = await PortalDeviceIdentity().clientId();
    expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{8,80}$')));
    expect(await PortalDeviceIdentity().clientId(), id);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('reads the device name or model and OS version on $platform without sending hardware IDs', () async {
      debugDefaultTargetPlatformOverride = platform;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'name': 'Studio phone',
          'systemName': 'iOS',
          'systemVersion': '27.0',
          'model': 'Demo model',
          'modelName': 'Demo model',
          'localizedModel': 'Demo model',
          'identifierForVendor': 'must-not-be-used',
          'isPhysicalDevice': false,
          'isiOSAppOnMac': false,
          'isiOSAppOnVision': false,
          'physicalRamSize': 4096,
          'availableRamSize': 2048,
          'freeDiskSize': 1024,
          'totalDiskSize': 2048,
          'utsname': {'sysname': '', 'nodename': '', 'release': '', 'version': '', 'machine': ''},
          'version': {
            'baseOS': '',
            'sdkInt': 36,
            'release': '16',
            'codename': '',
            'incremental': '',
            'previewSdkInt': 0,
            'securityPatch': '',
          },
          'board': '',
          'bootloader': '',
          'brand': '',
          'device': '',
          'display': '',
          'fingerprint': '',
          'hardware': '',
          'host': '',
          'id': 'must-not-be-used',
          'manufacturer': '',
          'product': '',
          'tags': '',
          'time': 0,
          'type': '',
          'isLowRamDevice': false,
        },
      );
      final info = await PortalDeviceIdentity().deviceInfo();
      expect(info.deviceName, platform == TargetPlatform.iOS ? 'Studio phone' : 'Demo model');
      expect(info.osVersion, platform == TargetPlatform.iOS ? '27.0' : '16');
      expect(info.appVersion, AppInfo.version);
      expect(info.toForm().values, isNot(contains('must-not-be-used')));
    });

    test('unavailable device metadata still sends installation identity on $platform', () async {
      debugDefaultTargetPlatformOverride = platform;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      final info = await PortalDeviceIdentity().deviceInfo();
      expect(info.clientId, matches(RegExp(r'^[A-Za-z0-9_-]{8,80}$')));
      expect(info.platform, platform == TargetPlatform.iOS ? 'iOS' : 'Android');
      expect(info.deviceName, isNotEmpty);
      expect(info.osVersion, isNotEmpty);
      expect(info.appVersion, isNotEmpty);
    });
  }
}
