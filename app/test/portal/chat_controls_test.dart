import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/message_actions.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => AppLocale.use(AppLocale.en));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  testWidgets('connected home keeps workspace/options but no tips or prompt cards', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: ChatEmptyState(
            connected: true,
            workspace: 'website',
            now: DateTime(2026, 1, 1, 12),
            options: const Text('Conversation options'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Conversation options'), findsOneWidget);
    expect(find.textContaining('website'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('workspace', findRichText: true), findsNothing);
    expect(find.textContaining('Tip'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply actions keep copy, branch and more but have no share action', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: ReplyActionRow(text: () => 'Reply', onBranch: () {}, onMore: () {}),
        ),
      ),
    );
    expect(find.byTooltip(appL10n.commonCopy), findsOneWidget);
    expect(find.byTooltip(appL10n.commonMore), findsOneWidget);
    expect(find.byTooltip(appL10n.commonShare), findsNothing);
    expect(find.byKey(const ValueKey('reply-share')), findsNothing);
  });
}
