import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

SessionLogEvent event(int seq, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1000 + seq, 'type': type, 'data': data});

class _Client extends DshClient {
  _Client(super.connection, {required this.running});
  final bool running;
  final updates = StreamController<DshEvent>.broadcast();

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) async* {
    yield snapshot(
      running
          ? [
              event(0, 'turn/start', {'turn': 1}),
            ]
          : [],
    );
    yield* updates.stream;
  }

  SessionSnapshotEvent snapshot(List<SessionLogEvent> events) => SessionSnapshotEvent(
    sessionId: 's',
    header: SessionHeader.fromJson({'id': 's', 'version': 4, 'createdAt': 1000}),
    cursor: events.isEmpty ? -1 : events.last.seq,
    events: events,
    hasMore: false,
    projections: const SessionProjections(-1, {}),
    assistantRevision: 0,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(FakeDsh, _Client, ProviderContainer)> fixture({bool running = true}) async {
    final host = await FakeDsh.start();
    final connected = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
    final client = _Client((connected.carrier as DshHttpCarrier).connection, running: running);
    await client.mux.ready();
    final container = ProviderContainer(
      overrides: [activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client)))],
    );
    final subscription = container.listen(chatProvider('s'), (_, _) {});
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await client.updates.close();
      await client.close();
      await connected.close();
      await host.close();
    });
    await container.read(chatProvider('s').notifier).waitForSync();
    return (host, client, container);
  }

  test('interrupt delegates to atomic host steer without canceling its delivery', () async {
    final (host, client, container) = await fixture();
    var canceled = false;
    host.handlers['session/cancel'] = (_) {
      canceled = true;
      return {
        'ok': true,
        'value': {'accepted': true},
      };
    };
    host.handlers['session/prompt'] = (args) {
      final request = args['request']! as Map;
      // A cancel acknowledgement need not mean the old driver has drained.
      if (!canceled) {
        client.updates.add(
          client.snapshot([
            event(0, 'turn/start', {'turn': 1}),
            event(1, 'user/message', {
              'id': 'steer',
              'role': 'user',
              'source': {'kind': 'user', 'rpcId': request['requestId']},
              'content': request['content'],
            }),
            event(2, 'assistant/message', {
              'turn': 1,
              'step': 2,
              'message': {
                'id': 'answer',
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'Updated reply'},
                ],
              },
            }),
            event(3, 'turn/end', {
              'turn': 1,
              'reason': {'kind': 'complete'},
            }),
          ]),
        );
      }
      return {
        'ok': true,
        'value': {'accepted': true},
      };
    };
    expect(await container.read(chatProvider('s').notifier).send('Change direction', mode: SendMode.interrupt), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final requests = host.rpcCalls.where((c) => c['method'] == 'session/prompt').toList();
    expect(canceled, isFalse);
    expect(((requests.single['payload'] as Map)['args'] as Map)['request'], containsPair('mode', 'steer'));
    final state = container.read(chatProvider('s'));
    expect(state.items.whereType<UserChatItem>().single.text, 'Change direction');
    expect(state.items.whereType<AssistantChatItem>().single.text, 'Updated reply');
    expect(state.pending, isEmpty);
    expect(state.running, isFalse);
  });

  test('empty interrupt makes no request', () async {
    final (host, _, container) = await fixture();
    expect(await container.read(chatProvider('s').notifier).send('  ', mode: SendMode.interrupt), isFalse);
    expect(host.rpcCalls, isEmpty);
  });

  test('send-now steers a queued occurrence without removing and deduplicating it', () async {
    final (host, _, container) = await fixture();
    host.handlers['session/updateQueue'] = (_) => {
      'ok': true,
      'value': {'accepted': true},
    };
    final prompt = PendingPrompt(
      requestId: 'accepted-request',
      inboxId: 'queued-occurrence',
      text: 'Change direction',
      time: DateTime.now(),
      slot: InboxSlot.nextTurn,
    );
    expect(await container.read(chatProvider('s').notifier).sendNow(prompt), isEmpty);
    expect(host.rpcCalls.single['method'], 'session/updateQueue');
    expect(((host.rpcCalls.single['payload'] as Map)['args'] as Map)['request'], {
      'sessionId': 's',
      'itemId': 'queued-occurrence',
      'action': {'kind': 'steer'},
    });
  });

  test('idle interrupt sends a normal prompt', () async {
    final (host, _, container) = await fixture(running: false);
    host.handlers['session/prompt'] = (_) => {
      'ok': true,
      'value': {'accepted': true},
    };
    expect(await container.read(chatProvider('s').notifier).send('Start', mode: SendMode.interrupt), isTrue);
    expect(((host.rpcCalls.single['payload'] as Map)['args'] as Map)['request'], containsPair('mode', 'queue'));
  });

  test('steer rejection returns the draft instead of leaving a pending bubble', () async {
    final (host, _, container) = await fixture();
    host.handlers['session/prompt'] = (_) => {
      'ok': false,
      'error': {'code': 'session/not-found', 'message': 'Gone', 'details': {}},
    };
    expect(await container.read(chatProvider('s').notifier).send('Keep this draft', mode: SendMode.interrupt), isFalse);
    expect(container.read(chatProvider('s')).pending, isEmpty);
    expect(container.read(chatProvider('s')).error, isNotNull);
  });
}
