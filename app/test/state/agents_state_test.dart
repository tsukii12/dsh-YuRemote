import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary _session(String id, {String? parent, Map<String, Object?> projections = const {}}) =>
    SessionSummary.fromJson({
      'sessionId': id,
      'updatedAt': 1,
      'parentSessionId': ?parent,
      if (parent != null) 'origin': 'subagent',
      'projections': {'kind': 'cached', 'asOfSeq': 1, 'values': projections},
    });

void main() {
  const lead = 'lead-1';
  final sessions = {
    lead: _session(
      lead,
      projections: {
        'agentTeam': {'enabled': true, 'tasks': []},
        'subagentCatalog': [
          {'id': 'child-1', 'mode': 'continuable', 'label': 'Review the diff', 'name': 'reviewer', 'createdAt': 1},
          {'id': 'ext-1', 'mode': 'external', 'label': 'CI', 'createdAt': 2},
        ],
      },
    ),
    'child-1': _session('child-1', parent: lead),
    'child-2': _session('child-2', parent: lead, projections: {'title': 'Fix the tests'}),
  };

  test('dsh 0.2.2 team: the roster comes from the Lead\'s subagent children', () {
    final team = resolveTeam(sessions[lead]!.projections.agentTeam, lead, sessions)!;
    expect(team.members.first.lead, isTrue);
    expect([for (final m in team.teammates) m.name], ['reviewer', 'Fix the tests']);
    expect(team.teammates.first.mode, SubagentMode.continuable);
  });

  test('team mode off hides the team', () {
    expect(resolveTeam(TeamSnapshot.fromJson({'enabled': false, 'tasks': []}), lead, sessions), isNull);
    expect(resolveTeam(null, lead, sessions), isNull);
  });

  test('a projected roster is kept as is', () {
    final team = TeamSnapshot.fromJson({
      'members': [
        {'id': lead, 'name': 'lead', 'role': 'lead'},
        {'id': 'x', 'name': 'writer'},
      ],
    });
    expect(resolveTeam(team, lead, sessions)!.teammates.single.name, 'writer');
  });
}
