import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Classes/previous_result.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/login_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/results_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/cie_sub_screen/widgets/cie_graph.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/see_sub_screen/latest_results.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/widgets/marks_card.dart';
import 'package:official_connect/Screens/login_screen/student_home/seating_screen/seating_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/timetable_screen/timetable_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/unified_screen.dart';
import 'package:official_connect/Services/exam_result_scraper.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _attendance(
  String code,
  String name, {
  String present = '1',
}) => {
  'code': code,
  'name': name,
  'teacher': 'Test Teacher',
  'present': present,
  'absent': '0',
  'remaining': '0',
  'percentage': '100%',
  'present_dates': <dynamic>[],
  'absent_dates': <dynamic>[],
};

Map<String, dynamic> _marks(String name, {String finalCie = '40'}) => {
  'name': name,
  't1': '-',
  't2': '-',
  'a1': '-',
  'a2': '-',
  'final cie': finalCie,
  'class_average': {'t1': '-', 't2': '-', 'a1': '-', 'a2': '-'},
};

Map<String, dynamic> _cachedData({bool includeCurrentSections = false}) => {
  'name': 'Cached Student',
  'proctorship': {'proctorial_notes': <dynamic>[], 'proctor_name': 'Not given'},
  'prevResults': <dynamic>[],
  'attendance': <dynamic>[],
  'fees': <dynamic>[],
  'marks': <dynamic>[],
  if (includeCurrentSections) 'timetable': <dynamic>[],
  if (includeCurrentSections) 'seating': <dynamic>[],
};

Future<void> _waitForCachedData(SisData sisData) async {
  for (var i = 0; i < 40 && sisData.data.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  test('cached portal data survives a simulated app restart', () async {
    SharedPreferences.setMockInitialValues({});
    final firstRun = SisData();
    await firstRun.loadDummyData();
    await firstRun.applyPortalData(
      {
        'name': 'Cache Test Student',
        'marks': <dynamic>[],
        '_sync': {'version': 1, 'sections': const {}},
      },
      'CACHE01',
      '2000-01-01',
    );
    expect(firstRun.hasData, isTrue);

    // A fresh provider against the same prefs is what a cold start does.
    final secondRun = SisData();
    for (var i = 0; i < 40 && !secondRun.hasData; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    expect(secondRun.hasData, isTrue);
    expect(secondRun.isValidData, isTrue);
    expect(secondRun.studentName, 'Cache Test Student');
    expect(secondRun.usn, 'CACHE01');
  });

  test('a corrupted cache resets cleanly instead of hanging', () async {
    SharedPreferences.setMockInitialValues({
      'hasData': true,
      'timeStamp': 0,
      'data': '{not valid json',
    });
    final sisData = SisData();
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (!sisData.hasData) break;
    }
    expect(sisData.hasData, isFalse);
    expect(sisData.data, isEmpty);
  });

  test('a fresh legacy cache requests a schema refresh', () async {
    SharedPreferences.setMockInitialValues({
      'hasData': true,
      'timeStamp': DateTime.now().millisecondsSinceEpoch,
      'usn': 'LEGACY01',
      'dob': '2000-01-01',
      'data': jsonEncode(_cachedData()),
    });

    final sisData = SisData();
    await _waitForCachedData(sisData);

    expect(sisData.hasData, isTrue);
    expect(sisData.needToUpdate, isTrue);
    expect(sisData.syncStatusFor('timetable'), 'unknown');
  });

  test('a fresh current cache does not request another refresh', () async {
    SharedPreferences.setMockInitialValues({
      'hasData': true,
      'timeStamp': DateTime.now().millisecondsSinceEpoch,
      'cacheSchemaVersion': SisData.currentCacheSchemaVersion,
      'usn': 'CURRENT01',
      'dob': '2000-01-01',
      'data': jsonEncode({
        ..._cachedData(includeCurrentSections: true),
        '_sync': {
          'sections': {
            'timetable': {'status': 'empty'},
            'seating': {'status': 'empty'},
          },
        },
      }),
    });

    final sisData = SisData();
    await _waitForCachedData(sisData);

    expect(sisData.needToUpdate, isFalse);
    expect(sisData.syncStatusFor('timetable'), 'empty');
  });

  test(
    'early attendance preserves optional cache and remains retryable after restart',
    () async {
      SharedPreferences.setMockInitialValues({
        'hasData': true,
        'usn': 'TEST001',
        'timeStamp': DateTime.now().millisecondsSinceEpoch,
        'cacheSchemaVersion': SisData.currentCacheSchemaVersion,
        'data': jsonEncode(_cachedData(includeCurrentSections: true)),
      });
      final sisData = SisData();
      await _waitForCachedData(sisData);
      expect(sisData.usn, 'TEST001');
      final oldMarks = jsonEncode(sisData.data['marks']);
      await sisData.applyPortalData(
        {
          'attendance': [_attendance('IS701', 'Updated subject', present: '9')],
          '_sync': {
            'outcome': 'partial',
            'sections': {
              'attendance': {'status': 'ok'},
              'timetable': {'status': 'pending'},
              'seating': {'status': 'pending'},
              'marks': {'status': 'pending'},
            },
          },
        },
        'TEST001',
        '2000-01-01',
      );
      expect(jsonEncode(sisData.data['marks']), oldMarks);
      expect(sisData.data['attendance'][0]['present'], '9');
      expect(sisData.isSyncPending, isTrue);
      expect(sisData.needToUpdate, isTrue);
      final restarted = SisData();
      await _waitForCachedData(restarted);
      expect(restarted.needToUpdate, isTrue);
      expect(restarted.isSyncPending, isTrue);
    },
  );

  test('an expired current cache keeps its refresh requirement', () async {
    SharedPreferences.setMockInitialValues({
      'hasData': true,
      'timeStamp': DateTime.now()
          .subtract(const Duration(hours: 13))
          .millisecondsSinceEpoch,
      'cacheSchemaVersion': SisData.currentCacheSchemaVersion,
      'data': jsonEncode(_cachedData(includeCurrentSections: true)),
    });

    final sisData = SisData();
    await _waitForCachedData(sisData);

    expect(sisData.needToUpdate, isTrue);
  });

  test('a failed timetable sync retries on the next launch', () async {
    SharedPreferences.setMockInitialValues({
      'hasData': true,
      'timeStamp': DateTime.now().millisecondsSinceEpoch,
      'cacheSchemaVersion': SisData.currentCacheSchemaVersion,
      'data': jsonEncode({
        ..._cachedData(includeCurrentSections: true),
        '_sync': {
          'sections': {
            'timetable': {'status': 'error'},
            'seating': {'status': 'empty'},
          },
        },
      }),
    });

    final sisData = SisData();
    await _waitForCachedData(sisData);

    expect(sisData.needToUpdate, isTrue);
    expect(sisData.syncStatusFor('timetable'), 'error');
  });

  test(
    'an attendance failure preserves saved rows and remains retryable',
    () async {
      SharedPreferences.setMockInitialValues({
        'hasData': true,
        'timeStamp': DateTime.now().millisecondsSinceEpoch,
        'cacheSchemaVersion': SisData.currentCacheSchemaVersion,
        'usn': 'ATTEND01',
        'dob': '2000-01-01',
        'data': jsonEncode({
          ..._cachedData(includeCurrentSections: true),
          'attendance': [_attendance('IS701', 'Saved subject')],
          '_sync': {
            'sections': {
              'attendance': {'status': 'ok'},
              'timetable': {'status': 'empty'},
              'seating': {'status': 'empty'},
            },
          },
        }),
      });
      final sisData = SisData();
      await _waitForCachedData(sisData);

      expect(sisData.needToUpdate, isFalse);
      await sisData.applyPortalData(
        {
          'name': 'Cached Student',
          'attendance': <dynamic>[],
          'timetable': <dynamic>[],
          'seating': <dynamic>[],
          '_sync': {
            'outcome': 'partial',
            'sections': {
              'attendance': {
                'status': 'error',
                'failure_reason': 'content_not_ready',
              },
              'timetable': {'status': 'empty'},
              'seating': {'status': 'empty'},
            },
          },
        },
        'ATTEND01',
        '2000-01-01',
      );

      expect(sisData.attendances, hasLength(1));
      expect(sisData.attendances.single.subjectName, 'Saved subject');
      expect(sisData.syncStatusFor('attendance'), 'error');
      expect(sisData.hasSyncIssues, isTrue);
    },
  );

  test(
    'an attendance partial result keeps the cache marked for refresh',
    () async {
      SharedPreferences.setMockInitialValues({
        'hasData': true,
        'timeStamp': DateTime.now().millisecondsSinceEpoch,
        'cacheSchemaVersion': SisData.currentCacheSchemaVersion,
        'usn': 'ATTEND02',
        'dob': '2000-01-01',
        'data': jsonEncode({
          ..._cachedData(includeCurrentSections: true),
          '_sync': {
            'sections': {
              'attendance': {'status': 'ok'},
              'timetable': {'status': 'empty'},
              'seating': {'status': 'empty'},
            },
          },
        }),
      });
      final sisData = SisData();
      await _waitForCachedData(sisData);

      await sisData.applyPortalData(
        {
          'name': 'Cached Student',
          'attendance': <dynamic>[
            _attendance('IS701', 'Subject', present: '2'),
          ],
          'timetable': <dynamic>[],
          'seating': <dynamic>[],
          '_sync': {
            'outcome': 'partial',
            'sections': {
              'attendance': {
                'status': 'partial',
                'failure_reason': 'content_not_ready',
              },
              'timetable': {'status': 'empty'},
              'seating': {'status': 'empty'},
            },
          },
        },
        'ATTEND02',
        '2000-01-01',
      );

      expect(sisData.attendances, hasLength(1));
      expect(sisData.needToUpdate, isTrue);
    },
  );

  test('a re-enabled timetable section retries on the next launch', () async {
    FirebaseFeatureFlags.setValuesForTesting(const {
      'scraper_timetable_enabled': true,
    });
    SharedPreferences.setMockInitialValues({
      'hasData': true,
      'timeStamp': DateTime.now().millisecondsSinceEpoch,
      'cacheSchemaVersion': SisData.currentCacheSchemaVersion,
      'data': jsonEncode({
        ..._cachedData(includeCurrentSections: true),
        '_sync': {
          'sections': {
            'timetable': {'status': 'disabled'},
            'seating': {'status': 'empty'},
          },
        },
      }),
    });

    final sisData = SisData();
    await _waitForCachedData(sisData);

    expect(sisData.needToUpdate, isTrue);
    FirebaseFeatureFlags.setValuesForTesting(const {});
  });

  testWidgets('legacy timetable cache offers an update action', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final sisData = SisData();
    await sisData.loadDummyData();
    await sisData.applyPortalData(
      {
        'name': 'Legacy Cache Student',
        '_sync': {'sections': const {}},
      },
      'LEGACY01',
      '2000-01-01',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: const MaterialApp(home: TimetableScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Update to load your timetable'), findsOneWidget);
    expect(find.text('Update data'), findsOneWidget);
    expect(find.text('No timetable available'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy seating cache reports a coarse exam seating state', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final sisData = SisData();
    await sisData.loadDummyData();
    await sisData.applyPortalData(
      {
        'name': 'Legacy Cache Student',
        '_sync': {'sections': const {}},
      },
      'LEGACY01',
      '2000-01-01',
    );

    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: const MaterialApp(home: SeatingScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final states = events
        .where((event) => event['name'] == 'feature_state_shown')
        .toList();
    expect(states, hasLength(1));
    expect(states.single['feature'], 'exam_seating');
    expect(states.single['state'], 'legacy_cache');
    expect(events.toString(), isNot(contains('LEGACY01')));
    expect(events.toString(), isNot(contains('Legacy Cache Student')));
    expect(tester.takeException(), isNull);

    SyncDiagnostics.configure(null);
    await SyncDiagnostics.setEnabled(true);
  });

  test('examination result HTML is converted into native result data', () {
    const html = '''
      <div class="stu-data stu-data2"><p>Even May 2026 Semester 6</p></div>
      <div class="credits-sec1"><p>Credits Registered: 20</p></div>
      <div class="credits-sec2"><p>Credits Earned: 20</p></div>
      <div class="credits-sec3"><p>SGPA: 8.75</p></div>
      <div class="credits-sec4"><p>CGPA: 8.41</p></div>
      <table class="uk-table res-table">
        <tr><th>Course Code</th><th>Subject Name</th><th>Credits Earned</th><th>Credits Reg.</th><th>Grade</th></tr>
        <tr><td>IS601</td><td>Cloud Computing</td><td>4</td><td>4</td><td>A</td></tr>
      </table>
    ''';
    final result = ExamResultScraper.parse(html, ExamResultSource.regular);

    expect(result.semesterNumber, '6');
    expect(result.sgpa, '8.75');
    expect(result.cgpa, '8.41');
    expect(result.results.single.subjectName, 'Cloud Computing');
    expect(result.results.single.grade, 'A');
  });

  test('backlog tables do not consume a semester number', () {
    Map<String, dynamic> result(String term, {String cgpa = '9.0'}) => {
      'term': term,
      'CGPA': cgpa,
      'Credits Earned ': '20',
      'Credits Registered ': '20',
      'SGPA': '9.0',
      'results': <Map<String, dynamic>>[],
    };

    final results = PreviousResult.getList([
      result('Back-Log Courses'),
      result('Jan 2023'),
      result('May/June 2023'),
    ]);

    expect(results[0].semesterNumber, 0);
    expect(results[1].semesterNumber, 1);
    expect(results[2].semesterNumber, 2);
  });

  test('partial portal updates preserve failed sections', () async {
    SharedPreferences.setMockInitialValues({});
    final sisData = SisData();
    await sisData.loadDummyData();
    // Bind the seeded cache to this test account before checking same-account
    // partial-update preservation.
    await sisData.applyPortalData(sisData.data, 'TEST', '2000-01-01');
    final previousAttendance = sisData.attendances.length;

    await sisData.applyPortalData(
      {
        'name': 'Updated Student',
        'marks': <dynamic>[],
        '_sync': {
          'version': 1,
          'outcome': 'partial',
          'sections': {
            'attendance': {'status': 'error'},
            'marks': {'status': 'empty'},
          },
        },
      },
      'TEST',
      '2000-01-01',
    );

    expect(sisData.attendances.length, previousAttendance);
    expect(sisData.marks, isEmpty);
    expect(sisData.hasSyncIssues, isTrue);
    expect(sisData.syncStatusFor('attendance'), 'error');
  });

  test('partial course updates merge cache by stable identity', () async {
    SharedPreferences.setMockInitialValues({});
    final sisData = SisData();
    await sisData.loadDummyData();
    await sisData.applyPortalData(
      {
        'name': 'Merge Test',
        'attendance': [
          _attendance('IS101', 'Old one', present: '2'),
          _attendance('IS102', 'Cached failed subject', present: '4'),
        ],
        'marks': [
          _marks('First Subject (IS101)', finalCie: '20'),
          _marks('Second Subject (IS102)', finalCie: '30'),
        ],
        '_sync': {'sections': const {}},
      },
      'MERGE01',
      '2000-01-01',
    );

    await sisData.applyPortalData(
      {
        'name': 'Merge Test',
        'attendance': [_attendance('IS101', 'New one', present: '9')],
        'marks': [_marks('Renamed Subject (IS101)', finalCie: '45')],
        '_sync': {
          'sections': {
            'attendance': {'status': 'partial'},
            'marks': {'status': 'partial'},
          },
        },
      },
      'MERGE01',
      '2000-01-01',
    );

    expect(sisData.attendances, hasLength(2));
    expect(
      sisData.attendances.singleWhere((item) => item.code == 'IS101').present,
      9,
    );
    expect(sisData.attendances.any((item) => item.code == 'IS102'), isTrue);
    expect(sisData.marks, hasLength(2));
    expect(
      sisData.marks
          .singleWhere((item) => item.subjectName.contains('IS101'))
          .finalCie,
      '45',
    );

    await sisData.applyPortalData(
      {
        'name': 'Merge Test',
        'attendance': [_attendance('IS101', 'Only current subject')],
        'marks': [_marks('Only current subject (IS101)')],
        '_sync': {
          'sections': {
            'attendance': {'status': 'ok'},
            'marks': {'status': 'ok'},
          },
        },
      },
      'MERGE01',
      '2000-01-01',
    );

    expect(sisData.attendances, hasLength(1));
    expect(sisData.marks, hasLength(1));
  });

  testWidgets('disabled result refresh keeps a cached result visible', (
    WidgetTester tester,
  ) async {
    FirebaseFeatureFlags.setValuesForTesting(const {
      'results_regular_enabled': false,
    });
    addTearDown(() => FirebaseFeatureFlags.setValuesForTesting(const {}));
    SharedPreferences.setMockInitialValues({
      'exam-result:regular:CACHE01':
          '{"term":"May 2026","creditsEarned":"20","creditsRegistered":"20","sgpa":"8.0","cgpa":"8.0","semesterNumber":6,"results":[]}',
    });
    final sisData = SisData();
    await sisData.loadDummyData();
    await sisData.applyPortalData(
      {
        'name': 'Cached Student',
        '_sync': {'sections': const {}},
      },
      'CACHE01',
      '2000-01-01',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: const MaterialApp(
          home: LatestResultsDetails(source: ExamResultSource.regular),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Latest regular result'), findsOneWidget);

    await tester.tap(find.byTooltip('Check for a newer result'));
    await tester.pumpAndSettle();

    expect(find.text('Latest regular result'), findsOneWidget);
    expect(find.textContaining('Showing your saved result'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  test('update diagnostics only emit bounded aggregate fields', () async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, parameters) async {
      events.add({'name': name, ...parameters});
    });
    await SyncDiagnostics.setEnabled(true);

    await SyncDiagnostics.recordSummary({
      'version': 1,
      'outcome': 'partial',
      'duration_ms': 999999999,
      'usn': 'SHOULD_NOT_APPEAR',
      'sections': {
        'attendance': {
          'status': 'partial',
          'count': 5,
          'failed': 1,
          'student_name': 'SHOULD_NOT_APPEAR',
        },
        'student-secret': {'status': 'error'},
      },
    }, refresh: true);

    final encoded = events.toString();
    expect(encoded, isNot(contains('SHOULD_NOT_APPEAR')));
    expect(encoded, isNot(contains('student-secret')));
    expect(encoded, contains('section: unknown'));
    expect(encoded, contains('duration_ms: 600000'));
  });

  testWidgets('student login opens the native verification form', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SisData(),
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Student Login'), findsOneWidget);
    await tester.tap(find.text('Student Login'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('usn')), findsOneWidget);
    expect(find.byKey(const ValueKey('dob')), findsOneWidget);
    expect(find.text('Verification type'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
  });

  testWidgets('dummy login loads populated offline data', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final sisData = SisData();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Student Login'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('usn')), 'DUMMY');
    await tester.ensureVisible(find.text('Login'));
    await tester.tap(find.text('Login'));
    await tester.pumpAndSettle();

    expect(sisData.hasData, isTrue);
    expect(sisData.isValidData, isTrue);
    expect(sisData.studentName, isNotEmpty);
    expect(sisData.attendances, isNotEmpty);
    expect(sisData.marks, isNotEmpty);
    expect(sisData.previousResults, isNotEmpty);
  });

  testWidgets('stale cached data remains navigable during refresh', (
    WidgetTester tester,
  ) async {
    // Phone-width surface: at tablet widths Unified shows a
    // NavigationRail instead of the BottomNavigationBar asserted below.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    SharedPreferences.setMockInitialValues({});
    final sisData = SisData();
    await sisData.loadDummyData();
    sisData.needToUpdate = true;
    Unified.screenNumber.value = 2;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: const MaterialApp(home: Unified()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Attendance'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsOneWidget);
  });

  testWidgets('SEE renders quick-result shortcuts without a runtime error', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final sisData = SisData();
    await sisData.loadDummyData();
    final showSee = ValueNotifier(false);
    addTearDown(showSee.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: MaterialApp(home: Scaffold(body: ResultsScreen(showSee))),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEE'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Quick results'), findsOneWidget);
    expect(find.text('Latest regular result'), findsOneWidget);
    expect(find.text('Supplementary results'), findsOneWidget);
  });

  testWidgets(
    'results fit a compact Galaxy viewport at large Android text scale',
    (WidgetTester tester) async {
      // A stricter compact viewport catches failures that can be hidden by
      // MediaQuery-only tests which do not change the render constraints.
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final sisData = SisData();
      await sisData.loadDummyData();
      final showSee = ValueNotifier(false);
      addTearDown(showSee.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: sisData,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 32),
                textScaler: const TextScaler.linear(2),
              ),
              child: child!,
            ),
            home: Scaffold(body: ResultsScreen(showSee)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester.getTopLeft(find.text('Results')).dy,
        greaterThanOrEqualTo(32),
      );
      expect(find.text('CIE'), findsOneWidget);
      expect(find.text('SEE'), findsOneWidget);
      expect(find.byType(CieGraph), findsOneWidget);

      final resultContext = tester.element(find.text('CIE'));
      expect(
        MediaQuery.textScalerOf(resultContext).scale(1),
        lessThanOrEqualTo(1.3),
      );

      final firstCourse = find.text(sisData.marks.first.subjectName);
      expect(firstCourse, findsOneWidget);
      expect(tester.getSize(firstCourse).height, lessThanOrEqualTo(55));

      await tester.tap(find.text('SEE'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Quick results'), findsOneWidget);
    },
  );

  testWidgets('Galaxy A52s layout keeps bottom navigation balanced', (
    WidgetTester tester,
  ) async {
    // 1080x2400 at Samsung's common 420 dpi setting is about 411x914 logical.
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final sisData = SisData();
    await sisData.loadDummyData();
    Unified.screenNumber.value = 1;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 32),
              textScaler: const TextScaler.linear(1.5),
            ),
            child: child!,
          ),
          home: const Unified(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final navigation = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(navigation.iconSize, greaterThanOrEqualTo(29));
    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byType(BottomNavigationBar)),
      ).scale(1),
      lessThanOrEqualTo(1.15),
    );
  });

  testWidgets('result subjects render as a compact table', (
    WidgetTester tester,
  ) async {
    final sisData = SisData();
    final subjects = [
      Subject(
        courseCode: 'IS601',
        subjectName: 'Cloud Computing',
        creditsEarned: '4',
        creditsRegistered: '4',
        gpa: '9',
        grade: 'A',
      ),
    ];

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: MaterialApp(
          home: Scaffold(body: MarksCard(subjects: subjects, isBackLog: false)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Course'), findsOneWidget);
    expect(find.text('Credits\nE / R'), findsOneWidget);
    expect(find.text('Result'), findsOneWidget);
    expect(find.text('Cloud Computing'), findsOneWidget);
    expect(find.text('4 / 4'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
  });
}
