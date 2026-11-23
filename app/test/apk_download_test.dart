import 'dart:async';
import 'dart:io';

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/update/apk_download.dart';
import 'package:dsh_app/update/apk_download_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_filex/open_filex.dart';

class PendingDownload extends ApkDownloader {
  final completed = Completer<File>();
  late void Function(int, int?) progress;
  bool cancelled = false;

  @override
  Future<File> download(Uri url, void Function(int, int?) onProgress) {
    progress = onProgress;
    return completed.future;
  }

  @override
  void cancel() {
    cancelled = true;
    super.cancel();
    if (!completed.isCompleted) completed.completeError(DownloadCancelled());
  }
}

class FakeInstaller extends ApkInstaller {
  ResultType result = ResultType.done;
  bool failSettings = false;
  int opened = 0;
  int settings = 0;

  @override
  Future<ResultType> open(File file) async {
    opened++;
    return result;
  }

  @override
  Future<void> openSettings() async {
    settings++;
    if (failSettings) throw StateError('unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final url = Uri.parse('https://example.com/update.apk');
  late Directory cache;
  setUp(() async => cache = await Directory.systemTemp.createTemp('apk-test-'));
  tearDown(() async => cache.delete(recursive: true));

  test('downloads into private cache, reports progress and retains complete APK', () async {
    final progress = <int>[];
    final downloader = ApkDownloader(
      cacheDirectory: () async => cache,
      client: MockClient((_) async => http.Response.bytes([0x50, 0x4b, 3, 4], 200)),
    );
    final file = await downloader.download(url, (received, total) {
      progress.add(received);
      expect(total, 4);
    });
    expect(file.path.startsWith(cache.path), isTrue);
    expect(file.path.endsWith('.apk'), isTrue);
    expect(await file.readAsBytes(), [0x50, 0x4b, 3, 4]);
    expect(progress.last, 4);
  });

  test('empty, invalid, failed and truncated downloads are removed', () async {
    for (final response in [
      http.StreamedResponse(Stream.value([]), 200),
      http.StreamedResponse(Stream.value([1, 2]), 200),
      http.StreamedResponse(Stream.value([0x50, 0x4b]), 200, contentLength: 4),
      http.StreamedResponse(Stream.value([]), 503),
      http.StreamedResponse(Stream.error(const SocketException('offline')), 200),
    ]) {
      final downloader = ApkDownloader(
        cacheDirectory: () async => cache,
        client: MockClient.streaming((_, _) async => response),
      );
      await expectLater(downloader.download(url, (_, _) {}), throwsA(anything));
      expect(await cache.list().toList(), isEmpty);
    }
  });

  test('unknown length works; cancellation removes partial APK', () async {
    final downloader = ApkDownloader(
      cacheDirectory: () async => cache,
      client: MockClient.streaming((_, _) async => http.StreamedResponse(Stream.value([0x50, 0x4b]), 200)),
    );
    final file = await downloader.download(url, (_, total) => expect(total, isNull));
    await file.parent.delete(recursive: true);
    late ApkDownloader cancelled;
    cancelled = ApkDownloader(
      cacheDirectory: () async => cache,
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.fromIterable([
            [0x50, 0x4b],
            [3, 4],
          ]),
          200,
        ),
      ),
    );
    await expectLater(cancelled.download(url, (_, _) => cancelled.cancel()), throwsA(isA<DownloadCancelled>()));
    expect(await cache.list().toList(), isEmpty);
  });

  test('rejects insecure URL and cancellation before download', () async {
    final downloader = ApkDownloader(cacheDirectory: () async => cache);
    await expectLater(downloader.download(Uri.parse('http://example.com/a.apk'), (_, _) {}), throwsFormatException);
    final cancelled = ApkDownloader(cacheDirectory: () async => cache)..cancel();
    await expectLater(cancelled.download(url, (_, _) {}), throwsA(isA<DownloadCancelled>()));
    expect(await cache.list().toList(), isEmpty);
  });

  test('installer checks permission and opens app-specific settings channel', () async {
    const channel = MethodChannel('io.github.tsukii12.dshremote/updates');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'canInstallPackages' ? false : null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final installer = ApkInstaller();
    expect(await installer.open(File('${cache.path}/update.apk')), ResultType.permissionDenied);
    await installer.openSettings();
    expect(calls, ['canInstallPackages', 'openInstallSettings']);
  });

  Future<void> show(
    WidgetTester tester,
    PendingDownload downloader,
    FakeInstaller installer,
    void Function(bool?) result,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result(
                  await showDialog<bool>(
                    context: context,
                    builder: (_) => ApkDownloadDialog(url: url, downloader: downloader, installer: installer),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('download progress and Cancel abort without browser fallback or installer', (tester) async {
    final downloader = PendingDownload();
    final installer = FakeInstaller();
    bool? result;
    await show(tester, downloader, installer, (value) => result = value);
    downloader.progress(50, 100);
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(downloader.cancelled, isTrue);
    expect(installer.opened, 0);
  });

  testWidgets('complete download opens installer; download and installer failures request browser', (tester) async {
    for (final scenario in ['done', 'network', 'installer']) {
      await tester.pumpWidget(const SizedBox());
      final downloader = PendingDownload();
      final installer = FakeInstaller()..result = scenario == 'installer' ? ResultType.error : ResultType.done;
      bool? result;
      await show(tester, downloader, installer, (value) => result = value);
      if (scenario == 'network') {
        downloader.completed.completeError(const SocketException('offline'));
      } else {
        downloader.completed.complete(File('${cache.path}/update.apk'));
      }
      await tester.pumpAndSettle();
      expect(result, scenario != 'done');
      expect(installer.opened, scenario == 'network' ? 0 : 1);
    }
  });

  testWidgets('denied installation guides to settings, supports retry and browser fallback', (tester) async {
    final downloader = PendingDownload();
    final installer = FakeInstaller()..result = ResultType.permissionDenied;
    bool? result;
    await show(tester, downloader, installer, (value) => result = value);
    downloader.completed.complete(File('${cache.path}/update.apk'));
    await tester.pumpAndSettle();
    expect(find.text('允许安装应用'), findsOneWidget);
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(installer.settings, 1);
    await tester.tap(find.text('重新安装'));
    await tester.pumpAndSettle();
    expect(installer.opened, 2);
    await tester.tap(find.text('在浏览器中下载'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('unavailable permission settings falls back to browser', (tester) async {
    final downloader = PendingDownload();
    final installer = FakeInstaller()
      ..result = ResultType.permissionDenied
      ..failSettings = true;
    bool? result;
    await show(tester, downloader, installer, (value) => result = value);
    downloader.completed.complete(File('${cache.path}/update.apk'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
