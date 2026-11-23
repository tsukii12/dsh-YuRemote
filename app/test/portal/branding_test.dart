import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/l10n/gen/app_localizations_en.dart';
import 'package:dsh_app/l10n/gen/app_localizations_zh.dart';
import 'package:dsh_app/share_code/conversation_html.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/share/share_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exported image filenames use the app brand', () {
    final exporter = ShareExporter(files: const FilesChannel(), clock: () => DateTime(2026, 10, 24, 15, 30, 12));
    expect(exporter.fileName(), 'YuRemote-20261024-153012.png');
  });

  test('both locales use descriptive product branding and short composer labels', () {
    for (final l10n in [L10nEn(), L10nZh()]) {
      expect(l10n.portalRemoteOnly, contains('DeepSeek Harness'));
      expect(l10n.chatComposerHint, contains('DSH'));
      expect(l10n.viewUiResendMessage('error'), contains('DSH'));
      expect(l10n.viewShareFileHint, contains(l10n.portalAppName));
      expect(l10n.viewContinueHeader('chat'), contains(l10n.portalAppName));
      expect(l10n.viewShareLinkText('chat', 'link'), contains(l10n.portalAppName));
      expect(l10n.viewShareBrandLine, contains(l10n.portalAppName));
      expect(l10n.viewShareBrandLineNoQr, contains(l10n.portalAppName));
      expect(l10n.remoteHostedUpdateRequired, contains(l10n.portalAppName));
      expect(l10n.systemActionsResultOffScreen, contains(l10n.portalAppName));
      expect(l10n.iosFilesFolderHint, contains('YuRemote'));
    }
  });

  test('exported viewer uses YuRemote branding, escapes titles and keeps a valid script CSP', () {
    final html = conversationHtml('{}', title: '<Chat>');
    expect(html, contains('<title>&lt;Chat&gt; · YuRemote</title>'));
    expect(html, contains('Open in YuRemote'));
    expect(html, contains('用鱼鱼远程打开'));
    expect(html, contains('Download YuRemote'));
    expect(html, contains('下载鱼鱼远程'));
    expect(html, contains('Update YuRemote to open this'));
    expect(html, contains('需要更新鱼鱼远程才能打开'));
    expect(html, contains('View chat · YuRemote'));
    expect(html, contains('查看对话 · 鱼鱼远程'));
    expect(html, contains('https://github.com/tsukii12/dsh-YuRemote/releases/latest'));
    expect(html, isNot(contains('https://github.com/ccch1mneyyy/dsh-go/releases/latest')));
    expect(html, isNot(contains('Open in dsh-go')));
    final script = RegExp(r'<script>([\s\S]*?)</script>').firstMatch(html)!.group(1)!;
    final digest = base64Encode(sha256.convert(utf8.encode(script)).bytes);
    expect(html, contains("script-src 'sha256-$digest'"));
    expect(conversationHtml('{}', title: ''), contains('<title> · YuRemote</title>'));
  });

  test('invalid file errors name the product without changing the envelope identifier', () {
    expect(readShareEnvelope('{"dshgo":1,"code":"abc"}').code, 'abc');
    expect(
      () => readShareEnvelope('{}'),
      throwsA(isA<ShareDecodeException>().having((e) => e.reason, 'reason', 'not a YuRemote conversation file')),
    );
  });
}
