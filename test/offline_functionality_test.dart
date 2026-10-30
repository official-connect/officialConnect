import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/login_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/see_sub_screen/latest_results.dart';
import 'package:official_connect/Screens/login_screen/student_home/unified_screen.dart';
import 'package:official_connect/Services/exam_result_scraper.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SisData> _restoreCachedStudent() async {
  final seed = SisData();
  await seed.loadDummyData();
  await seed.applyPortalData(seed.data, 'OFFLINE01', '2000-01-01');
  final restored = SisData();
  for (var i = 0; i < 40 && restored.data.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return restored;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Unified.screenNumber.value = 2;
  });

  testWidgets('first offline launch remains on a usable login screen', (
    tester,
  ) async {
    final sisData = SisData();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: const MaterialApp(home: Unified()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Student Login'), findsOneWidget);
    expect(sisData.hasData, isFalse);
  });

  test('cached academic sections restore without a network request', () async {
    final sisData = await _restoreCachedStudent();
    expect(sisData.attendances, isNotEmpty);
    expect(sisData.marks, isNotEmpty);
    expect(sisData.previousResults, isNotEmpty);
    expect(sisData.hasData, isTrue);
    expect(sisData.usn, 'OFFLINE01');
  });

  test(
    'failed marks update retains cached marks and remains retryable',
    () async {
      final sisData = await _restoreCachedStudent();
      final previous = jsonEncode(sisData.data['marks']);
      await sisData.applyPortalData(
        {
          'marks': <dynamic>[],
          '_sync': {
            'sections': {
              'attendance': {'status': 'ok'},
              'marks': {'status': 'error'},
              'timetable': {'status': 'ok'},
              'seating': {'status': 'ok'},
            },
          },
        },
        'OFFLINE01',
        '2000-01-01',
      );
      expect(jsonEncode(sisData.data['marks']), previous);
      expect(sisData.needToUpdate, isTrue);
      expect(sisData.hasSyncIssues, isTrue);
      sisData.dispose();
      final restored = SisData();
      await pumpEventQueue(times: 30);
      expect(jsonEncode(restored.data['marks']), previous);
      expect(restored.needToUpdate, isTrue);
      restored.dispose();
    },
  );

  test(
    'cached data restores while telemetry preference is unresponsive',
    () async {
      final seed = SisData();
      await seed.loadDummyData();
      await seed.applyPortalData(seed.data, 'OFFLINE01', '2000-01-01');
      seed.dispose();
      final pending = Completer<void>();
      var toggleCalled = false;
      SyncDiagnostics.configure(
        null,
        collectionToggle: (_) {
          toggleCalled = true;
          return pending.future;
        },
      );
      final restored = SisData();
      try {
        await pumpEventQueue(times: 30);
        expect(toggleCalled, isTrue);
        expect(pending.isCompleted, isFalse);
        expect(restored.attendances, isNotEmpty);
        expect(restored.marks, isNotEmpty);
        expect(restored.isValidData, isTrue);
      } finally {
        pending.complete();
        await pumpEventQueue(times: 30);
        SyncDiagnostics.configure(null);
        restored.dispose();
      }
    },
  );

  testWidgets('saved examination result opens without a network response', (
    tester,
  ) async {
    final sisData = SisData();
    await sisData.loadDummyData();
    await sisData.applyPortalData(sisData.data, 'OFFLINE01', '2000-01-01');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'exam-result:regular:OFFLINE01',
      jsonEncode({
        'cgpa': '8.4',
        'creditsEarned': '20',
        'creditsRegistered': '20',
        'sgpa': '8.7',
        'term': 'Even May 2026 Semester 6',
        'semesterNumber': '6',
        'results': [
          {
            'courseCode': 'IS601',
            'subjectName': 'Offline Systems',
            'creditsEarned': '4',
            'creditsRegistered': '4',
            'gpa': '9',
            'grade': 'A',
          },
        ],
      }),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: const MaterialApp(
          home: LatestResultsDetails(source: ExamResultSource.regular),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Offline Systems'), findsOneWidget);
    expect(find.text('Opening examination results'), findsNothing);
  });
}
