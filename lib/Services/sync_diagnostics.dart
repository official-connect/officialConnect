import 'dart:async';

import 'package:flutter/foundation.dart';

typedef DiagnosticsEventSink =
    Future<void> Function(String name, Map<String, Object> parameters);
typedef DiagnosticsCollectionToggle = Future<void> Function(bool enabled);
typedef DiagnosticsCrashContextSink =
    Future<void> Function(Map<String, String> values);
typedef DiagnosticsIssueSink =
    Future<void> Function(Map<String, String> values);
typedef DiagnosticsScreenReporter = Future<void> Function(String screen);

/// Build-stamped version/cohort for analytics segmentation.
///
/// Defaults to the current release; tests override via
/// [setReleaseForTesting]. Values are allowlisted before leaving the device.
class DiagnosticsRelease {
  static String? _appVersionOverride;
  static String? _platformOverride;

  static String get appVersion =>
      _safeReleaseToken(_appVersionOverride) ??
      const String.fromEnvironment('APP_VERSION', defaultValue: '1.1.5+13');

  static String get releaseCohort {
    final version = appVersion;
    final plus = version.indexOf('+');
    final cohort = plus >= 0 ? version.substring(0, plus) : version;
    return _safeReleaseToken(cohort) ?? 'unknown';
  }

  static String get platform {
    final override = _platformOverride?.trim().toLowerCase();
    if (override != null) {
      return {'android', 'ios', 'web'}.contains(override)
          ? override
          : 'unknown';
    }
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'unknown';
    }
  }

  static void setReleaseForTesting({String? appVersion, String? platform}) {
    _appVersionOverride = appVersion;
    _platformOverride = platform;
  }

  static void resetReleaseForTesting() {
    _appVersionOverride = null;
    _platformOverride = null;
  }

  static String? _safeReleaseToken(String? value) {
    final token = value?.trim().toLowerCase();
    if (token == null || token.isEmpty) return null;
    final normalized = token.length > 32 ? token.substring(0, 32) : token;
    return RegExp(r'^[a-z0-9][a-z0-9.+_-]*$').hasMatch(normalized)
        ? normalized
        : null;
  }
}

/// Emits only bounded, allowlisted operational health signals.
class SyncDiagnostics {
  static const _maxPendingEvents = 32;
  static const _sections = {
    'profile',
    'attendance',
    'marks',
    'proctor',
    'fees',
    'results',
    'timetable',
    'seating',
  };
  static const _outcomes = {
    'started',
    'success',
    'complete',
    'partial',
    'empty',
    'ok',
    'error',
    'disabled',
    'cancelled',
    'timeout',
    'session_expired',
    'network_error',
    'portal_attention',
    'parse_error',
  };
  static const _resultSources = {'regular', 'supplementary'};
  static const _loginStages = {
    'getting_ready',
    'signing_in',
    'scraping',
    'finishing',
    'needs_attention',
  };
  static const _attentionReasons = {
    'visibility_guarded',
    'manual_portal',
    'backgrounded',
    'cancelled',
    'disposed',
    'timeout',
  };
  static const _screens = {
    'explore',
    'results',
    'home',
    'attendance',
    'settings',
  };
  static const _features = {
    'fee_payment',
    'campus_helpdesk',
    'app_feedback',
    'report_bug',
    'source_code',
    'rate_app',
    'course_material',
    'syllabi',
    'club_details',
    'about',
    'update_data',
    'theme',
    'cie_marks',
    'semester_results',
    'result_details',
    'latest_regular_result',
    'supplementary_results',
    'timetable',
    'exam_seating',
  };
  static const _featureStates = {
    'loaded',
    'legacy_cache',
    'empty',
    'error',
    'disabled',
  };
  static const _failureReasons = {
    'missing_fields',
    'missing_links',
    'invalid_content',
    'session_expired',
    'parse_error',
    'timeout',
    'browser_not_ready',
    'empty_response',
    'request_error',
    'network_error',
    'content_not_ready',
    'cache_write',
    'cancelled',
    'state_error',
    'type_error',
    'range_error',
    'platform_error',
    'platform_unavailable',
    'unknown',
  };
  static const _failureKinds = {
    'session',
    'content',
    'portal_request',
    'timeout',
    'missing_plugin',
    'platform',
    'socket',
    'http_client',
    'format',
    'type',
    'range',
    'state',
    'other',
  };
  static const _diagnosticSections = {..._sections, 'dashboard'};
  static const _failureSteps = {
    'read',
    'parse',
    'checkpoint',
    'apply',
    'persist',
    'authenticate',
    'navigate',
    'unknown',
  };
  static const _refreshOutcomes = {
    'success',
    'partial',
    'error',
    'timeout',
    'disabled',
    'missing_login',
    'in_flight',
  };

  static DiagnosticsEventSink? _sink;
  static DiagnosticsCollectionToggle? _collectionToggle;
  static DiagnosticsCrashContextSink? _crashContextSink;
  static DiagnosticsScreenReporter? _screenReporter;
  static String _currentArea = 'startup';
  static bool _enabled = true;
  static final List<({String name, Map<String, Object> parameters})>
  _pendingEvents = [];

  static void configure(
    DiagnosticsEventSink? sink, {
    DiagnosticsCollectionToggle? collectionToggle,
  }) {
    _sink = sink;
    _collectionToggle = collectionToggle;
    if (sink == null) {
      _pendingEvents.clear();
      return;
    }
    if (_enabled) {
      final pending = List.of(_pendingEvents);
      _pendingEvents.clear();
      for (final event in pending) {
        unawaited(_deliver(sink, event.name, event.parameters));
      }
    }
  }

  static void configureCrashContext(DiagnosticsCrashContextSink? sink) {
    _crashContextSink = sink;
  }

  /// Retained as a compatibility seam for Firebase setup and tests. Expected
  /// sync outcomes are analytics events, not Crashlytics non-fatals.
  static void configureIssueReporting(DiagnosticsIssueSink? _) {}

  /// Sends the bounded screen name through the provider's standard screen API.
  ///
  /// This remains separate from [configure] so a provider failure cannot block
  /// the app's existing operational-event stream.
  static void configureScreenReporter(DiagnosticsScreenReporter? reporter) {
    _screenReporter = reporter;
    // The first Flutter route is often selected before Firebase has finished
    // initializing. Publish that one bounded route once the native reporter is
    // ready so the standard Screens report is not missing app startup.
    if (reporter != null && _enabled && _currentArea != 'startup') {
      unawaited(_reportScreen(_currentArea));
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (!enabled) _pendingEvents.clear();
    try {
      await _collectionToggle?.call(enabled);
    } catch (error) {
      debugPrint('Diagnostics collection preference could not be applied.');
    }
  }

  static Future<void> recordSummary(
    Map<String, dynamic> sync, {
    required bool refresh,
  }) async {
    final sections = sync['sections'] as Map? ?? const {};
    for (final entry in sections.entries) {
      final value = entry.value as Map? ?? const {};
      await _emit('sync_section', {
        'section': _safeSection(entry.key),
        'outcome': _safeOutcome(value['status']),
        'item_count': _safeCount(value['count']),
        'attempted_count': _safeCount(value['attempted']),
        'failed_count': _safeCount(value['failed']),
        'duration_ms': _safeDuration(value['duration_ms']),
        'duration_bucket': _durationBucket(value['duration_ms']),
        'sync_mode': refresh ? 'refresh' : 'first_login',
        'parser_version': _safeCount(sync['version']),
        if (value['failure_reason'] != null)
          'failure_reason': _safeFailureReason(value['failure_reason']),
      });
    }
    await _emit('sync_finished', {
      'outcome': _safeOutcome(sync['outcome']),
      'section_count': sections.length.clamp(0, _sections.length),
      'duration_ms': _safeDuration(sync['duration_ms']),
      'duration_bucket': _durationBucket(sync['duration_ms']),
      'sync_mode': refresh ? 'refresh' : 'first_login',
      'parser_version': _safeCount(sync['version']),
    });
  }

  static Future<void> recordFailure({
    required bool refresh,
    String stage = 'unknown',
    String reason = 'unknown',
    String? exceptionKind,
    String? section,
    String? step,
    int? durationMs,
    bool? hasCachedData,
  }) async {
    final safeStage = _loginStages.contains(stage) ? stage : 'unknown';
    final safeReason = _safeFailureReason(reason);
    final syncMode = refresh ? 'refresh' : 'first_login';
    await _emit('sync_finished', {
      'outcome': 'error',
      'sync_mode': syncMode,
      'failure_stage': safeStage,
      'failure_reason': safeReason,
      if (exceptionKind != null)
        'exception_kind': _safeFailureKind(exceptionKind),
      ..._failureContext(section, step, durationMs, hasCachedData),
    });
    await recordOperationalFailure(
      operation: 'sync',
      stage: safeStage,
      reason: safeReason,
      refresh: refresh,
      exceptionKind: exceptionKind,
      section: section,
      step: step,
      durationMs: durationMs,
      hasCachedData: hasCachedData,
    );
  }

  static Future<void> recordOperationalFailure({
    required String operation,
    required String stage,
    required String reason,
    required bool refresh,
    String? exceptionKind,
    String? section,
    String? step,
    int? durationMs,
    bool? hasCachedData,
  }) async {
    final safeOperation = {'sync', 'cache'}.contains(operation)
        ? operation
        : 'unknown';
    final safeStage = _loginStages.contains(stage) ? stage : 'unknown';
    final safeReason = _safeFailureReason(reason);
    final syncMode = refresh ? 'refresh' : 'first_login';
    final values = {
      'operation': safeOperation,
      'stage': safeStage,
      'reason': safeReason,
      // Share the section/sync report dimension; keep reason for older dashboards.
      'failure_reason': safeReason,
      'sync_mode': syncMode,
      if (exceptionKind != null)
        'exception_kind': _safeFailureKind(exceptionKind),
      ..._failureContext(section, step, durationMs, hasCachedData),
    };
    await _setCrashContext({
      'app_area': 'login',
      'app_operation': '${safeOperation}_failed',
      'operation_stage': safeStage,
      'failure_reason': safeReason,
      if (exceptionKind != null)
        'exception_kind': _safeFailureKind(exceptionKind),
      if (section != null) 'section': _safeDiagnosticSection(section),
      if (step != null) 'failure_step': _safeFailureStep(step),
      if (durationMs != null)
        'duration_ms': _safeDuration(durationMs).toString(),
      if (hasCachedData != null) 'has_cached_data': hasCachedData ? '1' : '0',
      'sync_mode': syncMode,
    });
    await _emit('operation_failure', values);
    // Recoverable refresh outcomes belong in Analytics and as breadcrumbs on
    // a real crash, not as synthetic Crashlytics exceptions. Recording each
    // retry here made ordinary portal/session failures look like app crashes.
  }

  static Future<void> recordRefreshOutcome(String outcome) => _emit(
    'refresh_finished',
    {'outcome': _refreshOutcomes.contains(outcome) ? outcome : 'unknown'},
  );

  static Future<void> recordLoginStarted({
    required bool refresh,
    String? flowId,
  }) async {
    _currentArea = 'login';
    await _setCrashContext({
      'app_area': _currentArea,
      'app_operation': 'login_started',
      'sync_mode': refresh ? 'refresh' : 'first_login',
    });
    await _emit('login_flow_started', {
      'sync_mode': refresh ? 'refresh' : 'first_login',
      if (flowId != null) 'flow_id': _safeFlowId(flowId),
    });
  }

  static Future<void> recordLoginFinished({
    required String outcome,
    required bool refresh,
    int? durationMs,
    String? flowId,
  }) async {
    final safeOutcome = _safeOutcome(outcome);
    await _setCrashContext({
      'app_area': 'login',
      'app_operation': 'login_finished',
      'operation_outcome': safeOutcome,
      'sync_mode': refresh ? 'refresh' : 'first_login',
    });
    await _emit('login_flow_finished', {
      'outcome': safeOutcome,
      'sync_mode': refresh ? 'refresh' : 'first_login',
      if (durationMs != null) 'duration_ms': _safeDuration(durationMs),
      if (flowId != null) 'flow_id': _safeFlowId(flowId),
    });
  }

  static Future<void> recordLoginAttention({
    required String reason,
    required String stage,
    required bool refresh,
    int? durationMs,
  }) async {
    final safeReason = _attentionReasons.contains(reason) ? reason : 'unknown';
    final safeStage = _loginStages.contains(stage) ? stage : 'unknown';
    await _setCrashContext({
      'app_area': 'login',
      'app_operation': 'login_attention',
      'operation_stage': safeStage,
      'attention_reason': safeReason,
      'sync_mode': refresh ? 'refresh' : 'first_login',
    });
    await _emit('login_flow_attention', {
      'reason': safeReason,
      'stage': safeStage,
      'sync_mode': refresh ? 'refresh' : 'first_login',
      if (durationMs != null) 'duration_ms': _safeDuration(durationMs),
    });
  }

  static Future<void> recordResult({
    required String source,
    required String outcome,
    int? durationMs,
  }) => _emit('result_fetch_finished', {
    'result_source': _resultSources.contains(source) ? source : 'unknown',
    'outcome': _safeOutcome(outcome),
    if (durationMs != null) 'duration_ms': _safeDuration(durationMs),
  });

  static Future<void> recordScreen(String screen) async {
    final safeScreen = _screens.contains(screen) ? screen : 'unknown';
    _currentArea = safeScreen;
    if (!_enabled) return;
    await _setCrashContext({
      'app_area': safeScreen,
      'app_operation': 'screen_view',
    });
    await _reportScreen(safeScreen);
    await _emit('app_screen_view', {'screen': safeScreen});
  }

  static Future<void> recordScreenDuration({
    required String screen,
    required int durationMs,
  }) => _emit('screen_time', {
    'screen': _screens.contains(screen) ? screen : 'unknown',
    'duration_ms': _safeDuration(durationMs),
  });

  static Future<void> recordFeature(
    String feature, {
    String? sourceScreen,
  }) async {
    final safeFeature = _features.contains(feature) ? feature : 'unknown';
    final source = sourceScreen == null
        ? _currentArea
        : (_screens.contains(sourceScreen) ? sourceScreen : 'unknown');
    await _setCrashContext({'app_area': source, 'app_operation': safeFeature});
    await _emit('feature_opened', {
      'feature': safeFeature,
      'source_screen': source,
    });
  }

  static Future<void> recordSupportAction({
    required String action,
    required String source,
    required String outcome,
    int? durationMs,
  }) => _emit('support_action', {
    'action':
        {
          'app_feedback',
          'report_bug',
          'source_code',
          'rate_app',
        }.contains(action)
        ? action
        : 'unknown',
    'source_screen': _screens.contains(source) ? source : 'unknown',
    'outcome': {'tapped', 'opened', 'error'}.contains(outcome)
        ? outcome
        : 'unknown',
    if (durationMs != null) 'duration_ms': _safeDuration(durationMs),
  });

  static Future<void> recordFeatureState(String feature, String state) =>
      _emit('feature_state_shown', {
        'feature': _features.contains(feature) ? feature : 'unknown',
        'state': _featureStates.contains(state) ? state : 'unknown',
      });

  static Future<void> recordPreference(String preference, String value) =>
      _emit('preference_changed', {
        'preference': _features.contains(preference) ? preference : 'unknown',
        'setting_value': _safePreferenceValue(preference, value),
      });

  static Map<String, Object> _withReleaseContext(
    Map<String, Object> parameters,
  ) {
    final enriched = Map<String, Object>.of(parameters);
    enriched.putIfAbsent('app_version', () => DiagnosticsRelease.appVersion);
    enriched.putIfAbsent(
      'release_cohort',
      () => DiagnosticsRelease.releaseCohort,
    );
    enriched.putIfAbsent('platform', () => DiagnosticsRelease.platform);
    return enriched;
  }

  static Future<void> _emit(String name, Map<String, Object> parameters) async {
    if (!_enabled) return;
    assert(() {
      debugPrint('Diagnostics: $name $parameters');
      return true;
    }());
    final enriched = _withReleaseContext(parameters);
    final sink = _sink;
    if (sink == null) {
      if (_pendingEvents.length == _maxPendingEvents) {
        _pendingEvents.removeAt(0);
      }
      _pendingEvents.add((name: name, parameters: Map.of(enriched)));
      return;
    }
    await _deliver(sink, name, enriched);
  }

  static Future<void> _deliver(
    DiagnosticsEventSink sink,
    String name,
    Map<String, Object> parameters,
  ) async {
    try {
      await sink(name, parameters);
    } catch (error) {
      // Operational diagnostics must never affect login, sync, or navigation.
      debugPrint('Diagnostics event could not be recorded.');
    }
  }

  static Future<void> _reportScreen(String screen) async {
    try {
      await _screenReporter?.call(screen);
    } catch (_) {
      // Navigation must remain usable when the analytics SDK is unavailable.
      debugPrint('Screen analytics could not be recorded.');
    }
  }

  static Future<void> _setCrashContext(Map<String, String> values) async {
    if (!_enabled) return;
    final enriched = Map<String, String>.of(values);
    enriched.putIfAbsent('app_version', () => DiagnosticsRelease.appVersion);
    try {
      await _crashContextSink?.call(enriched);
    } catch (_) {
      debugPrint('Crash context could not be recorded.');
    }
  }

  static String _safeToken(Object? value) {
    final token = value?.toString().toLowerCase() ?? 'unknown';
    return RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(token) ? token : 'unknown';
  }

  static String _safeSection(Object? value) {
    final token = _safeToken(value);
    return _sections.contains(token) ? token : 'unknown';
  }

  static String _safeOutcome(Object? value) {
    final token = _safeToken(value);
    return _outcomes.contains(token) ? token : 'unknown';
  }

  static String _safeFailureReason(Object? value) {
    final token = _safeToken(value);
    return _failureReasons.contains(token) ? token : 'unknown';
  }

  static String _safeFailureKind(Object? value) {
    final token = _safeToken(value);
    return _failureKinds.contains(token) ? token : 'other';
  }

  static String _safeDiagnosticSection(Object? value) {
    final token = _safeToken(value);
    return _diagnosticSections.contains(token) ? token : 'unknown';
  }

  static String _safeFailureStep(Object? value) {
    final token = _safeToken(value);
    return _failureSteps.contains(token) ? token : 'unknown';
  }

  static Map<String, Object> _failureContext(
    String? section,
    String? step,
    int? durationMs,
    bool? hasCachedData,
  ) => {
    if (section != null) 'section': _safeDiagnosticSection(section),
    if (step != null) 'failure_step': _safeFailureStep(step),
    if (durationMs != null) 'duration_ms': _safeDuration(durationMs),
    if (hasCachedData != null) 'has_cached_data': hasCachedData ? 1 : 0,
  };

  static String _safeFlowId(Object? value) {
    final token = value?.toString().toLowerCase() ?? 'unknown';
    return RegExp(r'^[a-z0-9]{1,24}$').hasMatch(token) ? token : 'unknown';
  }

  static int _safeCount(Object? value) {
    final count = int.tryParse(value?.toString() ?? '') ?? 0;
    return count.clamp(0, 1000);
  }

  static int _safeDuration(Object? value) {
    final duration = int.tryParse(value?.toString() ?? '') ?? 0;
    return duration.clamp(0, 600000);
  }

  /// Coarse duration histogram bucket. GA4 custom metrics expose only
  /// aggregates (no percentiles), so this dimension — once registered in
  /// the GA4 console — makes section and sync p50/p90/p99 directly
  /// queryable via event counts per bucket. Boundaries align with the
  /// scraper's own caps (3s fetch, 6s content wait, 15s load poll, 40s
  /// page read, 90s overall) so each bucket names the regime that bound
  /// the read. Values are part of the analytics contract: never rename.
  static String _durationBucket(Object? value) {
    final ms = _safeDuration(value);
    if (ms < 1000) return 'under_1s';
    if (ms < 3000) return '1_to_3s';
    if (ms < 6000) return '3_to_6s';
    if (ms < 15000) return '6_to_15s';
    if (ms < 40000) return '15_to_40s';
    if (ms < 90000) return '40_to_90s';
    return 'over_90s';
  }

  static String _safePreferenceValue(String preference, Object? value) {
    final token = _safeToken(value);
    if (preference == 'theme' && {'system', 'light', 'dark'}.contains(token)) {
      return token;
    }
    return 'unknown';
  }
}
