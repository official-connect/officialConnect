import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';

// Emulates complete user flows through SyncDiagnostics and asserts the
// exact emitted event contract: sequence, outcomes, release context, and
// opt-out suppression. Guards the gaps found in review (e.g. an event
// that never fires on some path must be a deliberate, locked-in absence).
void main() {
  final events = <Map<String, Object>>[];
  final contexts = <Map<String, String>>[];
  final issues = <Map<String, String>>[];
  final screens = <String>[];

  setUp(() async {
    events.clear();
    contexts.clear();
    issues.clear();
    screens.clear();
    DiagnosticsRelease.setReleaseForTesting(
      appVersion: '1.1.5+13',
      platform: 'android',
    );
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    SyncDiagnostics.configureCrashContext((values) async {
      contexts.add(Map.of(values));
    });
    SyncDiagnostics.configureIssueReporting((values) async {
      issues.add(Map.of(values));
    });
    SyncDiagnostics.configureScreenReporter((screen) async {
      screens.add(screen);
    });
    // Attaching the reporter replays the last area once (by design); drain
    // that async replay so each test starts from a clean contract.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    screens.clear();
  });

  tearDown(() {
    SyncDiagnostics.configure(null);
    SyncDiagnostics.configureCrashContext(null);
    SyncDiagnostics.configureIssueReporting(null);
    SyncDiagnostics.configureScreenReporter(null);
    DiagnosticsRelease.resetReleaseForTesting();
  });

  Future<void> enable() => SyncDiagnostics.setEnabled(true);

  void expectReleaseContext(Map<String, Object> event) {
    expect(event['app_version'], '1.1.5+13');
    expect(event['release_cohort'], '1.1.5');
    expect(event['platform'], 'android');
  }

  test('background refresh timeout emits started then timeout', () async {
    await enable();

    await SyncDiagnostics.recordLoginStarted(refresh: true, flowId: 'f1');
    await SyncDiagnostics.recordRefreshOutcome('timeout');

    expect(events.map((e) => e['name']), [
      'login_flow_started',
      'refresh_finished',
    ]);
    expect(events[0]['sync_mode'], 'refresh');
    expect(events[0]['flow_id'], 'f1');
    expect(events[1]['outcome'], 'timeout');
    for (final event in events) {
      expectReleaseContext(event);
    }
    expect(contexts.single['app_version'], '1.1.5+13');
  });

  test('full-login success never emits refresh_finished', () async {
    await enable();

    await SyncDiagnostics.recordLoginStarted(refresh: false, flowId: 'f2');
    await SyncDiagnostics.recordSummary(const {
      'outcome': 'complete',
      'sections': {
        'attendance': {'status': 'ok', 'count': 3},
      },
    }, refresh: false);
    await SyncDiagnostics.recordLoginFinished(
      outcome: 'success',
      refresh: false,
      flowId: 'f2',
    );

    // Locked-in by design: refresh_finished covers background refresh only.
    expect(events.map((e) => e['name']), [
      'login_flow_started',
      'sync_section',
      'sync_finished',
      'login_flow_finished',
    ]);
    expect(events.any((e) => e['name'] == 'refresh_finished'), isFalse);
  });

  test('missing-login refresh emits only its outcome', () async {
    await enable();

    await SyncDiagnostics.recordRefreshOutcome('missing_login');

    expect(events.map((e) => e['name']), ['refresh_finished']);
    expect(events.single['outcome'], 'missing_login');
    expectReleaseContext(events.single);
  });

  test('screen flow reports native screen and custom event', () async {
    await enable();

    await SyncDiagnostics.recordScreen('home');
    await SyncDiagnostics.recordScreenDuration(
      screen: 'home',
      durationMs: 1200,
    );

    expect(screens, ['home']);
    expect(events.map((e) => e['name']), ['app_screen_view', 'screen_time']);
    expect(events[0]['screen'], 'home');
    expect(events[1]['duration_ms'], 1200);
  });

  test(
    'failure path reports crash context and analytics without a synthetic crash',
    () async {
      await enable();

      await SyncDiagnostics.recordFailure(
        refresh: true,
        stage: 'scraping',
        reason: 'timeout',
      );

      expect(events.map((e) => e['name']), [
        'sync_finished',
        'operation_failure',
      ]);
      expect(events[0]['failure_reason'], 'timeout');
      expect(issues, isEmpty);
      for (final context in contexts) {
        expect(context['app_version'], '1.1.5+13');
      }
    },
  );

  test('disabled run emits nothing anywhere', () async {
    await SyncDiagnostics.setEnabled(false);

    await SyncDiagnostics.recordLoginStarted(refresh: true);
    await SyncDiagnostics.recordSummary(const {'outcome': 'ok'}, refresh: true);
    await SyncDiagnostics.recordLoginFinished(
      outcome: 'success',
      refresh: true,
    );
    await SyncDiagnostics.recordRefreshOutcome('success');
    await SyncDiagnostics.recordScreen('home');
    await SyncDiagnostics.recordFeature('timetable');
    await SyncDiagnostics.recordResult(source: 'regular', outcome: 'success');

    expect(events, isEmpty);
    expect(contexts, isEmpty);
    expect(issues, isEmpty);
    expect(screens, isEmpty);

    await enable();
  });

  test('summary emits cap-aligned duration buckets', () async {
    await enable();

    await SyncDiagnostics.recordSummary(const {
      'outcome': 'partial',
      'duration_ms': 57597,
      'sections': {
        'attendance': {'status': 'ok', 'duration_ms': 1809},
        'results': {'status': 'ok', 'duration_ms': 209},
        'timetable': {'status': 'timeout', 'duration_ms': 60449},
        'marks': {'status': 'ok', 'duration_ms': 3000},
        'fees': {'status': 'ok', 'duration_ms': 90000},
        'proctor': {'status': 'ok'},
      },
    }, refresh: true);

    final sections = events.where((e) => e['name'] == 'sync_section').toList();
    expect(sections, hasLength(6));
    expect(sections[0]['duration_bucket'], '1_to_3s');
    expect(sections[1]['duration_bucket'], 'under_1s');
    expect(sections[2]['duration_bucket'], '40_to_90s');
    expect(sections[3]['duration_bucket'], '3_to_6s');
    expect(sections[4]['duration_bucket'], 'over_90s');
    expect(sections[5]['duration_bucket'], 'under_1s');
    final finished = events.singleWhere((e) => e['name'] == 'sync_finished');
    expect(finished['duration_bucket'], '40_to_90s');
  });

  test('pending queue drops oldest beyond its cap', () async {
    await enable();
    SyncDiagnostics.configure(null);

    for (var i = 0; i < 40; i++) {
      await SyncDiagnostics.recordRefreshOutcome('success');
    }
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events, hasLength(32));
  });
}
