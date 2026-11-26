import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

class _FilesChannel extends FilesChannel {
  String? opened;
  String? saved;

  @override
  Future<void> open(String hostPath, {required String name, required String mime, bool chooser = false}) async {
    opened = hostPath;
  }

  @override
  Future<String> saveToDownloads(String hostPath, {required String name, required String mime}) async {
    saved = hostPath;
    return 'Download/$name';
  }
}

void main() {
  for (final action in ['preview', 'open', 'save']) {
    test('$action fetches an uncached artifact with one stat', () async {
      const path = 'fixture.png';
      const absolutePath = '/workspace/$path';
      final host = await FakeDsh.start();
      addTearDown(host.close);
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
      addTearDown(client.close);
      final root = await Directory.systemTemp.createTemp('artifact-file-stat');
      addTearDown(() => root.delete(recursive: true));
      host.handlers['workspaceFiles/stat'] = (_) => {
        'ok': true,
        'value': {'absolutePath': absolutePath, 'bytes': 3, 'version': 'v1'},
      };
      host.handlers['workspaceFiles/readBytes'] = (_) => {
        'ok': true,
        'value': {
          'data': [1, 2, 3],
          'eof': true,
          'version': 'v1',
        },
      };
      final channel = _FilesChannel();
      final files = ArtifactFiles(
        connection: HostConnection(client: client),
        channel: channel,
        cacheRoot: () async => root,
      );
      const artifact = Artifact(path: absolutePath, origin: ArtifactOrigin.linked, turn: 0);
      if (action == 'preview') {
        expect(await ArtifactImageReader(files).read('session', path), isA<RasterImage>());
      } else if (action == 'open') {
        await files.open('session', artifact);
        expect(await File(channel.opened!).readAsBytes(), [1, 2, 3]);
      } else {
        final stat = await client.statFile('session', path);
        expect(await files.saveToDownloads('session', artifact, knownStat: stat), 'Download/$path');
        expect(await File(channel.saved!).readAsBytes(), [1, 2, 3]);
      }
      expect(host.rpcCalls.map((call) => call['method']), ['workspaceFiles/stat', 'workspaceFiles/readBytes']);
    });
  }
}
