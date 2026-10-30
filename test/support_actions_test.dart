import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/student_home/settings_screen/settings_screen.dart';
import 'package:official_connect/Services/app_support.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final events = <Map<String, Object>>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SyncDiagnostics.configure(null);
    SyncDiagnostics.configureCrashContext(null);
    SyncDiagnostics.configureScreenReporter(null);
    await SyncDiagnostics.setEnabled(true);
    events.clear();
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
  });
  tearDown(() async {
    SyncDiagnostics.configure(null);
    await SyncDiagnostics.setEnabled(true);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<BuildContext> contextFor(WidgetTester tester) async {
    late BuildContext result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              result = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    return result;
  }

  final destinations = {
    'app_feedback': AppSupport.feedbackUrl,
    'report_bug': AppSupport.bugReportUrl,
    'source_code': AppSupport.sourceUrl,
    'rate_app': AppSupport.playStoreUrl,
  };
  for (final entry in destinations.entries) {
    testWidgets('${entry.key} records intent and launch with explicit source', (
      tester,
    ) async {
      final context = await contextFor(tester);
      await SyncDiagnostics.recordScreen('home');
      events.clear();
      Uri? opened;
      expect(
        await AppSupport.open(
          context,
          action: entry.key,
          source: 'settings',
          launcher: (uri) async {
            opened = uri;
            return true;
          },
        ),
        isTrue,
      );
      await tester.pump();
      expect(opened.toString(), entry.value);
      final actions = events
          .where((e) => e['name'] == 'support_action')
          .toList();
      expect(actions.map((e) => e['outcome']), ['tapped', 'opened']);
      expect(
        actions.every(
          (e) => e['action'] == entry.key && e['source_screen'] == 'settings',
        ),
        isTrue,
      );
      expect(actions.last['duration_ms'], isNonNegative);
      final feature = events.singleWhere((e) => e['name'] == 'feature_opened');
      expect(feature['feature'], entry.key);
      expect(feature['source_screen'], 'settings');
      expect(
        events.any(
          (e) => e.values.any((v) => v.toString().contains('https://')),
        ),
        isFalse,
      );
      expect(
        events.any(
          (e) => e['outcome'] == 'submitted' || e['outcome'] == 'completed',
        ),
        isFalse,
      );
    });
  }
  for (final throwsError in [false, true]) {
    testWidgets('failed launch is graceful (throws=$throwsError)', (
      tester,
    ) async {
      final context = await contextFor(tester);
      expect(
        await AppSupport.open(
          context,
          action: 'report_bug',
          source: 'settings',
          launcher: (_) async {
            if (throwsError) throw StateError('private exception details');
            return false;
          },
        ),
        isFalse,
      );
      await tester.pump();
      expect(
        events
            .where((e) => e['name'] == 'support_action')
            .map((e) => e['outcome']),
        ['tapped', 'error'],
      );
      expect(events.any((e) => e['name'] == 'feature_opened'), isFalse);
      expect(events.toString(), isNot(contains('private exception')));
      expect(find.text('Could not open that link. Try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });
  }
  testWidgets('opt-out suppresses events without preventing links', (
    tester,
  ) async {
    final context = await contextFor(tester);
    await SyncDiagnostics.setEnabled(false);
    events.clear();
    expect(
      await AppSupport.open(
        context,
        action: 'app_feedback',
        source: 'explore',
        launcher: (_) async => true,
      ),
      isTrue,
    );
    await tester.pump();
    expect(events, isEmpty);
  });
  testWidgets('an unresponsive analytics sink cannot block link opening', (
    tester,
  ) async {
    final context = await contextFor(tester);
    final pending = Completer<void>();
    SyncDiagnostics.configure((_, __) => pending.future);
    expect(
      await AppSupport.open(
        context,
        action: 'source_code',
        source: 'settings',
        launcher: (_) async => true,
      ),
      isTrue,
    );
    pending.complete();
    await tester.pump();
  });
  test('support parameters are bounded and allowlisted', () async {
    await SyncDiagnostics.recordSupportAction(
      action: 'student secret',
      source: 'private url',
      outcome: 'form contents',
      durationMs: -10,
    );
    expect(events.single['action'], 'unknown');
    expect(events.single['source_screen'], 'unknown');
    expect(events.single['outcome'], 'unknown');
    expect(events.single['duration_ms'], 0);
  });
  for (final size in [const Size(320, 640), const Size(800, 1280)]) {
    testWidgets('Settings support actions remain reachable at 2x text $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final data = SisData()..themeMode = size.width < 600 ? 'dark' : 'light';
      addTearDown(data.dispose);
      final opened = <Uri>[];
      await tester.pumpWidget(
        ChangeNotifierProvider<SisData>.value(
          value: data,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SettingsInfo(
                linkLauncher: (uri) async {
                  opened.add(uri);
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final action in destinations.keys) {
        final target = find.byKey(ValueKey('support-$action'));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(opened.map((uri) => uri.toString()), destinations.values);
    });
  }
  testWidgets('iOS keeps support links without a Play Store action', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final data = SisData();
    addTearDown(data.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<SisData>.value(
        value: data,
        child: const MaterialApp(home: Scaffold(body: SettingsInfo())),
      ),
    );
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(find.byKey(const ValueKey('support-rate_app')), findsNothing);
    expect(find.byKey(const ValueKey('support-report_bug')), findsOneWidget);
    expect(find.byKey(const ValueKey('support-source_code')), findsOneWidget);
  });
}
