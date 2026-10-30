import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Services/app_distribution.dart';
import 'package:official_connect/Services/firebase_crash_reporting.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';

void main() {
  tearDown(() {
    FirebaseFeatureFlags.setValuesForTesting(const {});
    SyncDiagnostics.configure(null);
    SyncDiagnostics.configureCrashContext(null);
    SyncDiagnostics.configureIssueReporting(null);
    SyncDiagnostics.configureScreenReporter(null);
    DiagnosticsRelease.resetReleaseForTesting();
    FirebaseFeatureFlags.configureRefreshForTesting(null);
  });

  test('distribution marker fails closed outside production', () {
    expect(AppDistribution.normalize('production'), 'production');
    expect(AppDistribution.normalize(' PRODUCTION '), 'production');
    expect(AppDistribution.normalize('internal_test'), 'local');
    expect(AppDistribution.normalize('release'), 'local');
    expect(AppDistribution.normalize(''), 'local');
  });

  test('feature controls default to enabled and compose safely', () {
    FirebaseFeatureFlags.setValuesForTesting(const {});
    expect(FirebaseFeatureFlags.portalSyncEnabled, isTrue);
    expect(FirebaseFeatureFlags.automaticRefreshEnabled, isTrue);
    expect(FirebaseFeatureFlags.sectionEnabled('attendance'), isTrue);
    expect(FirebaseFeatureFlags.resultSourceEnabled('regular'), isTrue);
  });

  test('portal switch disables portal sections and automatic refresh', () {
    FirebaseFeatureFlags.setValuesForTesting(const {
      FirebaseFeatureFlags.portalSyncKey: false,
    });
    expect(FirebaseFeatureFlags.portalSyncEnabled, isFalse);
    expect(FirebaseFeatureFlags.automaticRefreshEnabled, isFalse);
    expect(FirebaseFeatureFlags.sectionEnabled('marks'), isFalse);
    expect(FirebaseFeatureFlags.resultSourceEnabled('regular'), isTrue);
  });

  test('individual sections and result sources can be disabled', () {
    FirebaseFeatureFlags.setValuesForTesting(const {
      'scraper_marks_enabled': false,
      FirebaseFeatureFlags.supplementaryResultsKey: false,
    });
    expect(FirebaseFeatureFlags.sectionEnabled('marks'), isFalse);
    expect(FirebaseFeatureFlags.sectionEnabled('attendance'), isTrue);
    expect(FirebaseFeatureFlags.resultSourceEnabled('supplementary'), isFalse);
    expect(FirebaseFeatureFlags.resultSourceEnabled('regular'), isTrue);
    expect(FirebaseFeatureFlags.resultSourceEnabled('invented'), isFalse);
  });

  test('telemetry emits only bounded allowlisted operational data', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordLoginStarted(refresh: false);
    await SyncDiagnostics.recordLoginFinished(
      outcome: 'student_identifier_PRIVATE_ACCOUNT',
      refresh: false,
      durationMs: 999999999,
    );
    await SyncDiagnostics.recordLoginAttention(
      reason: 'student_identifier_PRIVATE_ACCOUNT',
      stage: 'PRIVATE_DATE',
      refresh: false,
      durationMs: 999999999,
    );
    await SyncDiagnostics.recordResult(
      source: 'PRIVATE_ACCOUNT',
      outcome: '<html>secret</html>',
      durationMs: -12,
    );
    await SyncDiagnostics.recordSummary({
      'outcome': 'complete',
      'sections': {
        '1MS00XX999': {'status': 'ok'},
        'marks': {'status': 'error', 'failure_reason': 'PRIVATE_ACCOUNT'},
      },
    }, refresh: true);

    final encoded = events.toString();
    expect(encoded, isNot(contains('PRIVATE_ACCOUNT')));
    expect(encoded, isNot(contains('private_account')));
    expect(encoded, isNot(contains('<html>')));
    expect(encoded, contains('outcome: unknown'));
    expect(encoded, contains('duration_ms: 600000'));
    expect(encoded, contains('duration_ms: 0'));
    expect(encoded, contains('section: unknown'));
    expect(encoded, contains('reason: unknown'));
    expect(encoded, contains('stage: unknown'));
    expect(encoded, contains('failure_reason: unknown'));
  });

  test(
    'login attention diagnostics use only coarse allowlisted values',
    () async {
      final events = <Map<String, Object>>[];
      SyncDiagnostics.configure((name, parameters) async {
        events.add({'name': name, ...parameters});
      });
      await SyncDiagnostics.setEnabled(true);

      await SyncDiagnostics.recordLoginAttention(
        reason: 'manual_portal',
        stage: 'needs_attention',
        refresh: false,
        durationMs: 1234,
      );

      expect(events, hasLength(1));
      expect(events.single['name'], 'login_flow_attention');
      expect(events.single['reason'], 'manual_portal');
      expect(events.single['stage'], 'needs_attention');
      expect(events.single['sync_mode'], 'first_login');
      expect(events.single['duration_ms'], 1234);
      expect(events.single['app_version'], DiagnosticsRelease.appVersion);
      expect(events.single['release_cohort'], DiagnosticsRelease.releaseCohort);
      expect(events.single['platform'], DiagnosticsRelease.platform);
    },
  );

  test('cancelled login emits a terminal funnel outcome', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordLoginStarted(refresh: false);
    await SyncDiagnostics.recordLoginFinished(
      outcome: 'cancelled',
      refresh: false,
      durationMs: 900,
    );

    expect(events.map((event) => event['name']), [
      'login_flow_started',
      'login_flow_finished',
    ]);
    expect(events.last['outcome'], 'cancelled');
    expect(events.last['sync_mode'], 'first_login');
  });

  test('timed-out login emits a terminal timeout outcome', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordLoginStarted(refresh: false);
    await SyncDiagnostics.recordLoginFinished(
      outcome: 'timeout',
      refresh: false,
      durationMs: 900,
    );

    expect(events.map((event) => event['name']), [
      'login_flow_started',
      'login_flow_finished',
    ]);
    expect(events.last['outcome'], 'timeout');
    expect(events.last['sync_mode'], 'first_login');
  });

  test('disabled collection suppresses all operational events', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(false);
    await SyncDiagnostics.recordLoginStarted(refresh: true);
    await SyncDiagnostics.recordResult(source: 'regular', outcome: 'success');
    expect(events, isEmpty);
  });

  test('feature analytics accepts only coarse allowlisted values', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordScreen('results');
    await SyncDiagnostics.recordFeature('fee_payment');
    await SyncDiagnostics.recordPreference('theme', 'dark');
    await SyncDiagnostics.recordScreen('PRIVATE_ACCOUNT');
    await SyncDiagnostics.recordFeature('marks_for_PRIVATE_ACCOUNT');
    await SyncDiagnostics.recordPreference('theme', 'PRIVATE_DATE');

    expect(
      events.any(
        (event) =>
            event['name'] == 'app_screen_view' && event['screen'] == 'results',
      ),
      isTrue,
    );
    expect(
      events.any(
        (event) =>
            event['name'] == 'feature_opened' &&
            event['feature'] == 'fee_payment',
      ),
      isTrue,
    );
    expect(
      events.any(
        (event) =>
            event['name'] == 'preference_changed' &&
            event['preference'] == 'theme' &&
            event['setting_value'] == 'dark',
      ),
      isTrue,
    );
    final encoded = events.toString();
    expect(encoded, isNot(contains('PRIVATE_ACCOUNT')));
    expect(encoded, isNot(contains('PRIVATE_DATE')));
    expect(encoded, contains('feature: unknown'));
    expect(encoded, contains('setting_value: unknown'));
  });

  test('screen reporter receives only safe screen names', () async {
    final reportedScreens = <String>[];
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    SyncDiagnostics.configureScreenReporter((screen) async {
      reportedScreens.add(screen);
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordScreen('results');
    await SyncDiagnostics.recordScreen('PRIVATE_ACCOUNT');

    expect(reportedScreens.sublist(reportedScreens.length - 2), [
      'results',
      'unknown',
    ]);
    expect(
      events.where((event) => event['name'] == 'app_screen_view'),
      hasLength(2),
    );
  });

  test(
    'screen reporter catches the startup route after Firebase is ready',
    () async {
      final reportedScreens = <String>[];
      await SyncDiagnostics.setEnabled(true);
      await SyncDiagnostics.recordScreen('home');

      SyncDiagnostics.configureScreenReporter((screen) async {
        reportedScreens.add(screen);
      });

      expect(reportedScreens, ['home']);
    },
  );

  test(
    'screen reporter failures never interrupt navigation diagnostics',
    () async {
      final events = <Map<String, Object>>[];
      SyncDiagnostics.configure((name, parameters) async {
        events.add({'name': name, ...parameters});
      });
      SyncDiagnostics.configureScreenReporter(
        (_) async => throw StateError('analytics unavailable'),
      );
      await SyncDiagnostics.setEnabled(true);

      await expectLater(SyncDiagnostics.recordScreen('home'), completes);
      expect(events.single['name'], 'app_screen_view');
    },
  );

  test('feature state analytics cannot contain account data', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordFeatureState('timetable', 'legacy_cache');
    await SyncDiagnostics.recordFeatureState(
      'timetable_for_PRIVATE_ACCOUNT',
      'PRIVATE_VALUE',
    );

    expect(events.first['name'], 'feature_state_shown');
    expect(events.first['feature'], 'timetable');
    expect(events.first['state'], 'legacy_cache');
    expect(events.last['feature'], 'unknown');
    expect(events.last['state'], 'unknown');
    for (final event in events) {
      expect(event['app_version'], DiagnosticsRelease.appVersion);
      expect(event['release_cohort'], DiagnosticsRelease.releaseCohort);
      expect(event['platform'], DiagnosticsRelease.platform);
    }
    expect(events.toString(), isNot(contains('PRIVATE_ACCOUNT')));
    expect(events.toString(), isNot(contains('PRIVATE_VALUE')));
  });

  test('exam seating state analytics cannot contain account data', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordFeatureState('exam_seating', 'loaded');
    await SyncDiagnostics.recordFeatureState('exam_seating', 'empty');
    await SyncDiagnostics.recordFeatureState('exam_seating', 'disabled');
    await SyncDiagnostics.recordFeatureState(
      'exam_seating_for_PRIVATE_ACCOUNT',
      'PRIVATE_VALUE',
    );

    expect(events[0]['feature'], 'exam_seating');
    expect(events[0]['state'], 'loaded');
    expect(events[1]['state'], 'empty');
    expect(events[2]['state'], 'disabled');
    expect(events.last['feature'], 'unknown');
    expect(events.last['state'], 'unknown');
    expect(events.toString(), isNot(contains('PRIVATE_ACCOUNT')));
    expect(events.toString(), isNot(contains('PRIVATE_VALUE')));
  });

  test('disabled collection suppresses feature state events', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(false);
    await SyncDiagnostics.recordFeatureState('exam_seating', 'loaded');
    await SyncDiagnostics.recordFeatureState('timetable', 'error');
    expect(events, isEmpty);
  });

  test(
    'result fetch terminal outcomes stay allowlisted without abandonment',
    () async {
      final events = <Map<String, Object>>[];
      SyncDiagnostics.configure((name, parameters) async {
        events.add({'name': name, ...parameters});
      });
      await SyncDiagnostics.setEnabled(true);

      await SyncDiagnostics.recordResult(source: 'regular', outcome: 'success');
      await SyncDiagnostics.recordResult(source: 'regular', outcome: 'error');
      await SyncDiagnostics.recordResult(
        source: 'supplementary',
        outcome: 'network_error',
      );
      await SyncDiagnostics.recordResult(
        source: 'regular',
        outcome: 'disabled',
      );
      // Low completion alone is not evidence of abandonment: an unrecognized
      // outcome must stay 'unknown' rather than inventing an 'abandoned' state.
      await SyncDiagnostics.recordResult(
        source: 'regular',
        outcome: 'abandoned',
      );

      final outcomes = events.map((event) => event['outcome']).toList();
      expect(outcomes, [
        'success',
        'error',
        'network_error',
        'disabled',
        'unknown',
      ]);
      expect(events.toString(), isNot(contains('abandoned')));
    },
  );

  test(
    'crash context uses only coarse allowlisted navigation values',
    () async {
      final contexts = <Map<String, String>>[];
      SyncDiagnostics.configureCrashContext((values) async {
        contexts.add(Map.of(values));
      });
      await SyncDiagnostics.setEnabled(true);

      await SyncDiagnostics.recordScreen('results');
      await SyncDiagnostics.recordFeature('cie_marks');
      await SyncDiagnostics.recordFeature('marks_for_PRIVATE_ACCOUNT');
      await SyncDiagnostics.recordLoginAttention(
        reason: 'student_identifier_PRIVATE_ACCOUNT',
        stage: 'PRIVATE_DATE',
        refresh: false,
      );

      expect(contexts[0]['app_area'], 'results');
      expect(contexts[0]['app_operation'], 'screen_view');
      expect(contexts[0]['app_version'], DiagnosticsRelease.appVersion);
      expect(contexts[1]['app_area'], 'results');
      expect(contexts[1]['app_operation'], 'cie_marks');
      expect(contexts[1]['app_version'], DiagnosticsRelease.appVersion);
      expect(contexts[2]['app_operation'], 'unknown');
      expect(contexts[3]['operation_stage'], 'unknown');
      expect(contexts[3]['attention_reason'], 'unknown');
      expect(contexts.toString(), isNot(contains('PRIVATE_ACCOUNT')));
      expect(contexts.toString(), isNot(contains('PRIVATE_DATE')));
    },
  );

  test(
    'top-level sync failures report only bounded operational context',
    () async {
      final events = <Map<String, Object>>[];
      final issues = <Map<String, String>>[];
      SyncDiagnostics.configure((name, parameters) async {
        events.add({'name': name, ...parameters});
      });
      SyncDiagnostics.configureIssueReporting((values) async {
        issues.add(Map.of(values));
      });
      await SyncDiagnostics.setEnabled(true);

      await SyncDiagnostics.recordFailure(
        refresh: true,
        stage: 'scraping',
        reason: 'student_PRIVATE_ACCOUNT',
        exceptionKind: 'platform',
      );

      expect(events.first['name'], 'sync_finished');
      expect(events.first['outcome'], 'error');
      expect(events.first['sync_mode'], 'refresh');
      expect(events.first['failure_stage'], 'scraping');
      expect(events.first['failure_reason'], 'unknown');
      expect(events.first['exception_kind'], 'platform');
      expect(events.first['app_version'], DiagnosticsRelease.appVersion);
      expect(events.last['name'], 'operation_failure');
      expect(events.last['operation'], 'sync');
      expect(events.last['stage'], 'scraping');
      expect(events.last['reason'], 'unknown');
      expect(events.last['failure_reason'], 'unknown');
      expect(events.last['exception_kind'], 'platform');
      expect(events.last['sync_mode'], 'refresh');
      expect(events.last['app_version'], DiagnosticsRelease.appVersion);
      expect(issues, isEmpty);
      expect('$events$issues', isNot(contains('PRIVATE_ACCOUNT')));
    },
  );

  test(
    'failure context is bounded and preserves safe section progress',
    () async {
      final events = <Map<String, Object>>[];
      SyncDiagnostics.configure((name, parameters) async {
        events.add({'name': name, ...parameters});
      });
      await SyncDiagnostics.setEnabled(true);
      await SyncDiagnostics.recordFailure(
        refresh: true,
        stage: 'scraping',
        reason: 'timeout',
        section: 'dashboard',
        step: 'parse',
        durationMs: 700001,
        hasCachedData: true,
      );
      expect(events.first['section'], 'dashboard');
      expect(events.first['failure_step'], 'parse');
      expect(events.first['duration_ms'], 600000);
      expect(events.first['has_cached_data'], 1);
      expect(events.last['section'], 'dashboard');
      expect(events.last['failure_step'], 'parse');
      expect(events.toString(), isNot(contains('PRIVATE')));
    },
  );

  test('login flow identifiers are bounded and pair terminal events', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordLoginStarted(refresh: true, flowId: 'abc123');
    await SyncDiagnostics.recordLoginFinished(
      outcome: 'success',
      refresh: true,
      flowId: 'abc123',
    );
    await SyncDiagnostics.recordLoginStarted(
      refresh: false,
      flowId: 'student_PRIVATE_ACCOUNT',
    );

    expect(events[0]['flow_id'], 'abc123');
    expect(events[1]['flow_id'], 'abc123');
    expect(events[2]['flow_id'], 'unknown');
    expect(events.toString(), isNot(contains('PRIVATE_ACCOUNT')));
  });

  test('startup events wait for Firebase and flush once configured', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure(null);
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordScreen('home');
    await SyncDiagnostics.recordFeature('cie_marks');
    expect(events, isEmpty);

    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await Future<void>.delayed(Duration.zero);

    expect(events.length, 2);
    expect(events.first['screen'], 'home');
    expect(events.last['feature'], 'cie_marks');
  });

  test('opting out discards events queued before Firebase starts', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure(null);
    await SyncDiagnostics.setEnabled(true);
    await SyncDiagnostics.recordScreen('home');

    await SyncDiagnostics.setEnabled(false);
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
  });

  test('startup event buffer stays bounded', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure(null);
    await SyncDiagnostics.setEnabled(true);
    for (var i = 0; i < 40; i++) {
      await SyncDiagnostics.recordScreen('home');
    }

    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(32));
  });

  test('diagnostics sink failures never propagate', () async {
    SyncDiagnostics.configure((_, __) async => throw StateError('offline'));
    await SyncDiagnostics.setEnabled(true);

    await expectLater(
      SyncDiagnostics.recordLoginStarted(refresh: false),
      completes,
    );
    await expectLater(
      SyncDiagnostics.recordSummary({
        'outcome': 'partial',
        'sections': {
          'marks': {'status': 'error'},
        },
      }, refresh: true),
      completes,
    );
  });

  test('collection toggle failures never propagate', () async {
    SyncDiagnostics.configure(
      null,
      collectionToggle: (_) async => throw StateError('unavailable'),
    );
    await expectLater(SyncDiagnostics.setEnabled(false), completes);
  });

  test('feature refresh is fail-open and throttled while offline', () async {
    var attempts = 0;
    FirebaseFeatureFlags.configureRefreshForTesting(() async {
      attempts++;
      throw StateError('offline');
    });

    await FirebaseFeatureFlags.refresh();
    await FirebaseFeatureFlags.refresh();

    expect(attempts, 1);
    expect(FirebaseFeatureFlags.portalSyncEnabled, isTrue);
  });

  test('release context is attached to every operational event', () async {
    DiagnosticsRelease.setReleaseForTesting(
      appVersion: '1.1.4+12',
      platform: 'android',
    );
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordLoginStarted(refresh: false);
    await SyncDiagnostics.recordScreen('home');

    expect(events, hasLength(2));
    for (final event in events) {
      expect(event['app_version'], '1.1.4+12');
      expect(event['release_cohort'], '1.1.4');
      expect(event['platform'], 'android');
    }
  });

  test('release cohort derives from the build number suffix', () async {
    DiagnosticsRelease.setReleaseForTesting(
      appVersion: '2.0.1+44',
      platform: 'ios',
    );
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordResult(source: 'regular', outcome: 'success');

    expect(events.single['app_version'], '2.0.1+44');
    expect(events.single['release_cohort'], '2.0.1');
    expect(events.single['platform'], 'ios');
  });

  test('untrusted release values never leak into analytics', () async {
    DiagnosticsRelease.setReleaseForTesting(
      appVersion: 'student_PRIVATE_ACCOUNT <html>',
      platform: 'PRIVATE_OS',
    );
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordScreen('home');

    expect(events.single['app_version'], isNot(contains('PRIVATE')));
    expect(events.single['platform'], 'unknown');
    expect(events.toString(), isNot(contains('PRIVATE_ACCOUNT')));
    expect(events.toString(), isNot(contains('<html>')));
  });

  test('opt-out still suppresses versioned events', () async {
    DiagnosticsRelease.setReleaseForTesting(
      appVersion: '1.1.4+12',
      platform: 'android',
    );
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(false);

    await SyncDiagnostics.recordLoginStarted(refresh: true);
    await SyncDiagnostics.recordScreen('home');

    expect(events, isEmpty);
  });

  test('breadcrumbs summarize sync flow with bounded tokens', () async {
    expect(
      FirebaseCrashReporting.breadcrumbFor('sync_section', {
        'section': 'timetable',
        'outcome': 'ok',
      }),
      'sync:timetable:ok',
    );
    expect(
      FirebaseCrashReporting.breadcrumbFor('sync_finished', {
        'outcome': 'partial',
        'sync_mode': 'refresh',
      }),
      'sync:finished:partial:refresh',
    );
    expect(
      FirebaseCrashReporting.breadcrumbFor('refresh_finished', {
        'outcome': 'timeout',
      }),
      'refresh:timeout',
    );
    expect(
      FirebaseCrashReporting.breadcrumbFor('app_screen_view', {
        'screen': 'home',
      }),
      isNull,
    );
    expect(
      FirebaseCrashReporting.breadcrumbFor('sync_section', {
        'section': 'student_PRIVATE_ACCOUNT <html>',
        'outcome': 'ok',
      }),
      isNull,
    );
  });

  test('breadcrumb logging is inert when collection is off', () async {
    await FirebaseCrashReporting.logBreadcrumb('sync:timetable:ok');
  });

  test(
    'crash context carries the app version for release segmentation',
    () async {
      DiagnosticsRelease.setReleaseForTesting(appVersion: '1.1.4+12');
      final contexts = <Map<String, String>>[];
      SyncDiagnostics.configureCrashContext((values) async {
        contexts.add(Map.of(values));
      });
      await SyncDiagnostics.setEnabled(true);

      await SyncDiagnostics.recordScreen('home');

      expect(contexts.single['app_version'], '1.1.4+12');
    },
  );
}
