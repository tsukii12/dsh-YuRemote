import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/l10n/gen/app_localizations_en.dart';
import 'package:dsh_app/l10n/gen/app_localizations_zh.dart';
import 'package:dsh_app/share_code/conversation_html.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('both locales use descriptive product branding and short composer labels', () {
    for (final l10n in [L10nEn(), L10nZh()]) {
      expect(l10n.portalRemoteOnly, contains('DeepSeek Harness'));
      expect(l10n.chatComposerHint, contains('DSH'));
      expect(l10n.viewUiResendMessage('error'), contains('DSH'));
      expect(l10n.viewShareFileHint, contains('DeepSeek Harness'));
    }
  });

  test('exported viewer uses DSH branding, escapes titles and keeps a valid script CSP', () {
    final html = conversationHtml('{}', title: '<Chat>');
    expect(html, contains('<title>&lt;Chat&gt; · DSH</title>'));
    expect(html, contains('Open in DSH'));
    expect(html, contains('用 DSH 打开'));
    expect(html, isNot(contains('Open in dsh-go')));
    final script = RegExp(r'<script>([\s\S]*?)</script>').firstMatch(html)!.group(1)!;
    final digest = base64Encode(sha256.convert(utf8.encode(script)).bytes);
    expect(html, contains("script-src 'sha256-$digest'"));
    expect(conversationHtml('{}', title: ''), contains('<title> · DSH</title>'));
  });

  test('invalid file errors name the product without changing the envelope identifier', () {
    expect(readShareEnvelope('{"dshgo":1,"code":"abc"}').code, 'abc');
    expect(
      () => readShareEnvelope('{}'),
      throwsA(
        isA<ShareDecodeException>().having((e) => e.reason, 'reason', 'not a DeepSeek Harness conversation file'),
      ),
    );
  });
}
