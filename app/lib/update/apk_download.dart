import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

class DownloadCancelled implements Exception {}

class ApkDownloader {
  ApkDownloader({http.Client? client, Future<Directory> Function()? cacheDirectory})
    : _client = client ?? http.Client(),
      _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;
  final _abort = Completer<void>();

  void cancel() {
    if (!_abort.isCompleted) _abort.complete();
    _client.close();
  }

  void _checkCancelled() {
    if (_abort.isCompleted) throw DownloadCancelled();
  }

  Future<File> download(Uri url, void Function(int received, int? total) onProgress) async {
    Directory? directory;
    RandomAccessFile? output;
    try {
      if (url.scheme != 'https') throw const FormatException('APK URL must use HTTPS');
      final cache = await _cacheDirectory();
      _checkCancelled();
      directory = await cache.createTemp('yuremote-update-');
      final file = File('${directory.path}/update.apk');
      final response = await _client
          .send(http.AbortableRequest('GET', url, abortTrigger: _abort.future))
          .timeout(const Duration(seconds: 30));
      _checkCancelled();
      if (response.statusCode != 200) throw HttpException('APK download failed (${response.statusCode})');
      final total = response.contentLength;
      var received = 0;
      output = await file.open(mode: FileMode.write);
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        _checkCancelled();
        await output.writeFrom(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      _checkCancelled();
      await output.close();
      output = null;
      if (received == 0 || (total != null && total != received)) throw const FormatException('Incomplete APK');
      final header = await file.openRead(0, 2).fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
      if (header.length != 2 || header[0] != 0x50 || header[1] != 0x4b) throw const FormatException('Invalid APK');
      return file;
    } catch (_) {
      await output?.close();
      if (directory != null && await directory.exists()) await directory.delete(recursive: true);
      if (_abort.isCompleted) throw DownloadCancelled();
      rethrow;
    } finally {
      _client.close();
    }
  }
}

class ApkInstaller {
  static const _channel = MethodChannel('io.github.tsukii12.dshremote/updates');

  Future<ResultType> open(File file) async {
    if (await _channel.invokeMethod<bool>('canInstallPackages') != true) return ResultType.permissionDenied;
    return (await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive')).type;
  }

  Future<void> openSettings() => _channel.invokeMethod<void>('openInstallSettings');
}
