import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/main.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/portal_refresh.dart';
import 'package:official_connect/Screens/login_screen/student_home/unified_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/timetable_screen/timetable_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/seating_screen/seating_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _VisualData extends SisData {
  // Never fetch real profile photos during deterministic offline smoke tests.
  @override
  String get studentImage => '';
}

// Generate local, synthetic-data captures with:
// flutter test --update-goldens --dart-define=CAPTURE_UI=true test/ui_visual_smoke_test.dart
// Optionally set SMOKE_ROBOTO to a local Roboto-Regular.ttf for default labels.
// Captures live under ignored build/ rather than public source control.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Comfortaa',
    )..addFont(rootBundle.load('fonts/Comfortaa-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    const roboto = String.fromEnvironment('SMOKE_ROBOTO');
    if (roboto.isNotEmpty) {
      final bytes = await File(roboto).readAsBytes();
      await (FontLoader(
        'Roboto',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final size in [
    const Size(320, 640),
    const Size(412, 915),
    const Size(800, 1280),
  ]) {
    testWidgets('real app root preserves logical viewport $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MyApp());
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pump(const Duration(milliseconds: 400));
      final context = tester.element(find.byType(Navigator).first);
      expect(MediaQuery.sizeOf(context), size);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    for (final dark in [false, true]) {
      testWidgets('traverse ${size.width} ${dark ? "dark" : "light"}', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final data = _VisualData();
        await data.loadDummyData();
        data.themeMode = dark ? 'dark' : 'light';
        addTearDown(data.dispose);
        Unified.screenNumber.value = 2;
        addTearDown(() => Unified.screenNumber.value = 2);
        const captureKey = ValueKey('smoke-capture');
        Widget app(Widget screen) => ChangeNotifierProvider<SisData>.value(
          value: data,
          child: MaterialApp(
            home: RepaintBoundary(key: captureKey, child: screen),
          ),
        );
        await tester.pumpWidget(app(const Unified()));
        await tester.pumpAndSettle();
        for (final label in [
          'Home',
          'Results',
          'Attendance',
          'Explore',
          'Settings',
        ]) {
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: label);
          if (const bool.fromEnvironment('CAPTURE_UI')) {
            await expectLater(
              find.byKey(captureKey),
              matchesGoldenFile(
                '../build/ui-smoke/${size.width.toInt()}-${dark ? "dark" : "light"}-${label.toLowerCase()}.png',
              ),
            );
          }
          if (label == 'Home') {
            backgroundSyncState.value = BackgroundSyncState.updating;
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull);
            if (const bool.fromEnvironment('CAPTURE_UI')) {
              await expectLater(
                find.byKey(captureKey),
                matchesGoldenFile(
                  '../build/ui-smoke/${size.width.toInt()}-${dark ? "dark" : "light"}-home-updating.png',
                ),
              );
            }
            backgroundSyncState.value = BackgroundSyncState.idle;
            await tester.pumpAndSettle();
            await tester.drag(
              find.byType(SingleChildScrollView).first,
              const Offset(0, -1600),
            );
            await tester.pumpAndSettle();
            final details = find.byType(ExpansionTile).last;
            await tester.ensureVisible(details);
            await tester.tap(details);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'expanded Home card',
            );
            if (const bool.fromEnvironment('CAPTURE_UI')) {
              await expectLater(
                find.byKey(captureKey),
                matchesGoldenFile(
                  '../build/ui-smoke/${size.width.toInt()}-${dark ? "dark" : "light"}-home-details.png',
                ),
              );
            }
          }
          if (label == 'Settings') {
            await tester.ensureVisible(
              find.byKey(const ValueKey('support-source_code')),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            if (const bool.fromEnvironment('CAPTURE_UI')) {
              await expectLater(
                find.byKey(captureKey),
                matchesGoldenFile(
                  '../build/ui-smoke/${size.width.toInt()}-${dark ? "dark" : "light"}-settings-support.png',
                ),
              );
            }
          }
        }
        for (final entry in {
          'timetable': const TimetableScreen(),
          'seating': const SeatingScreen(),
        }.entries) {
          await tester.pumpWidget(app(entry.value));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: entry.key);
          if (const bool.fromEnvironment('CAPTURE_UI')) {
            await expectLater(
              find.byKey(captureKey),
              matchesGoldenFile(
                '../build/ui-smoke/${size.width.toInt()}-${dark ? "dark" : "light"}-${entry.key}.png',
              ),
            );
          }
        }
        final today = DateTime.now().toIso8601String().split('T').first;
        await data.applyPortalData(
          {
            ...data.data,
            'timetable': [
              {
                'date': today,
                'day': 'Today',
                'time': '09:00 - 10:00',
                'name': 'Systems modelling and control',
                'code': 'TEST01',
                'faculty': 'Demo Faculty',
                'room': 'AB504',
                'batch': 'B1',
              },
            ],
            'seating': [
              {
                'date': '2099-01-01',
                'course_name': 'Systems modelling and control',
                'course_code': 'TEST01',
                'timing': '09:30 - 12:30',
                'session': 'Morning session',
                'block': 'APEX BLOCK',
                'room': 'AB504',
              },
            ],
          },
          'DEMO01',
          '2000-01-01',
        );
        for (final entry in {
          'timetable-loaded': const TimetableScreen(),
          'seating-loaded': const SeatingScreen(),
        }.entries) {
          await tester.pumpWidget(app(entry.value));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: entry.key);
          if (const bool.fromEnvironment('CAPTURE_UI')) {
            await expectLater(
              find.byKey(captureKey),
              matchesGoldenFile(
                '../build/ui-smoke/${size.width.toInt()}-${dark ? "dark" : "light"}-${entry.key}.png',
              ),
            );
          }
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
