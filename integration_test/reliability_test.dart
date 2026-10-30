import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/portal_refresh.dart';
import 'package:official_connect/Screens/login_screen/portal_login_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/unified_screen.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Run only on the named disposable emulator. Preferences are saved in memory
// and restored; no real credentials or portal requests are used by this suite.
class _OfflineStudent extends SisData {
  @override
  String get studentImage => '';
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'Operation exceeded integration deadline');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late Map<String, Object> original;

  setUp(() async {
    prefs = await SharedPreferences.getInstance();
    original = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
    await prefs.setBool('hasData', false);
    SyncDiagnostics.configure((_, __) async {});
    Unified.screenNumber.value = 2;
  });

  tearDown(() async {
    backgroundSyncState.value = BackgroundSyncState.idle;
    SyncDiagnostics.configure(null);
    for (final key in prefs.getKeys().difference(original.keys.toSet())) {
      await prefs.remove(key);
    }
    for (final entry in original.entries) {
      switch (entry.value) {
        case String value:
          await prefs.setString(entry.key, value);
        case bool value:
          await prefs.setBool(entry.key, value);
        case int value:
          await prefs.setInt(entry.key, value);
        case double value:
          await prefs.setDouble(entry.key, value);
        case List<String> value:
          await prefs.setStringList(entry.key, value);
      }
    }
  });

  testWidgets(
    'native cache restores while telemetry is stalled; navigation stays usable',
    (tester) async {
      final seed = _OfflineStudent();
      await seed.loadDummyData();
      await seed.applyPortalData(seed.data, 'DUMMY', '2000-01-01');
      seed.dispose();
      final pending = Completer<void>();
      SyncDiagnostics.configure(
        (_, __) async {},
        collectionToggle: (_) => pending.future,
      );
      final restored = _OfflineStudent();
      try {
        await _until(tester, () => restored.marks.isNotEmpty);
        expect(pending.isCompleted, isFalse);
        restored.needToUpdate = false;
        await tester.pumpWidget(
          ChangeNotifierProvider<SisData>.value(
            value: restored,
            child: const MaterialApp(home: Unified()),
          ),
        );
        await tester.pumpAndSettle();
        backgroundSyncState.value = BackgroundSyncState.updating;
        await tester.pump(const Duration(milliseconds: 100));
        for (final label in [
          'Results',
          'Attendance',
          'Explore',
          'Settings',
          'Home',
        ]) {
          await tester.tap(find.text(label).last);
          // An active update indicator animates indefinitely: do not settle it.
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull, reason: label);
          expect(
            Unified.screenNumber.value,
            {
              'Explore': 0,
              'Results': 1,
              'Home': 2,
              'Attendance': 3,
              'Settings': 4,
            }[label],
            reason: 'Navigation must switch to $label while updating',
          );
        }
        expect(Unified.screenNumber.value, 2);
        expect(restored.marks, isNotEmpty);
      } finally {
        pending.complete();
        await tester.pumpWidget(const SizedBox());
        restored.dispose();
      }
    },
  );

  testWidgets(
    'native preferences preserve good marks after malformed refresh',
    (tester) async {
      final seed = _OfflineStudent();
      await seed.loadDummyData();
      await seed.applyPortalData(seed.data, 'DUMMY', '2000-01-01');
      final marks = jsonEncode(seed.data['marks']);
      await seed.applyPortalData(
        {
          ...seed.data,
          'marks': [
            {'invalid': true},
          ],
        },
        'DUMMY',
        '2000-01-01',
      );
      expect(seed.syncStatusFor('marks'), 'error');
      seed.dispose();
      await prefs.reload();
      final restored = _OfflineStudent();
      try {
        await _until(tester, () => restored.data.isNotEmpty);
        expect(jsonEncode(restored.data['marks']), marks);
        expect(restored.syncStatusFor('marks'), 'error');
      } finally {
        restored.dispose();
      }
    },
  );

  testWidgets(
    'real Android WebView reads local DOM and survives repeated disposal',
    (tester) async {
      for (var cycle = 0; cycle < 3; cycle++) {
        final loaded = Completer<InAppWebViewController>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  PortalBrowserViewport(
                    hidden: cycle > 0,
                    child: InAppWebView(
                      key: ValueKey(cycle),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                      ),
                      initialData: InAppWebViewInitialData(
                        data:
                            '<html><body><p id="probe">ready</p></body></html>',
                      ),
                      onLoadStop: (controller, _) {
                        if (!loaded.isCompleted) loaded.complete(controller);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await _until(tester, () => loaded.isCompleted);
        final controller = await loaded.future;
        expect(
          await controller
              .evaluateJavascript(
                source: "document.getElementById('probe').textContent",
              )
              .timeout(const Duration(seconds: 10)),
          'ready',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
    },
  );
}
