import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _healthy({String name = 'Student A'}) => {
  'name': name,
  'attendance': <dynamic>[],
  'marks': [
    {
      'name': 'Algorithms (CS101)',
      'a1': '10',
      'a2': '10',
      't1': '10',
      't2': '10',
      'final cie': '40',
      'class_average': {'a1': '8', 'a2': '8', 't1': '8', 't2': '8'},
    },
  ],
  'fees': [
    {'Academic Year': '2025-26', 'Amount Paid': '100'},
  ],
  'proctorship': {'proctor_name': 'Advisor A', 'proctorial_notes': <dynamic>[]},
  'prevResults': <dynamic>[],
  'timetable': <dynamic>[],
  'seating': <dynamic>[],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'malformed marks preserve the cached section and update good sections',
    () async {
      final data = SisData();
      await data.applyPortalData(_healthy(), 'USERA', '2000-01-01');
      final oldMarks = jsonEncode(data.data['marks']);

      await data.applyPortalData(
        {
          ..._healthy(name: 'Updated Student'),
          'marks': <dynamic>[
            {'broken': true},
          ],
          '_sync': {'sections': const {}},
        },
        'USERA',
        '2000-01-01',
      );

      expect(jsonEncode(data.data['marks']), oldMarks);
      expect(data.data['name'], 'Updated Student');
      expect(data.syncStatusFor('marks'), 'error');
      expect(
        (data.syncMetadata['sections'] as Map)['marks']['failure_reason'],
        'parse_error',
      );
      expect(data.syncMetadata['outcome'], 'partial');
      data.dispose();
    },
  );

  test('malformed proctor and fees sections do not blank other data', () async {
    final data = SisData();
    await data.applyPortalData(_healthy(), 'USERA', '2000-01-01');
    final marks = jsonEncode(data.data['marks']);
    final proctor = jsonEncode(data.data['proctorship']);
    final fees = jsonEncode(data.data['fees']);

    await data.applyPortalData(
      {
        ..._healthy(name: 'Good profile'),
        'proctorship': {
          'proctorial_notes': [42],
        },
        'fees': <dynamic>[42],
        '_sync': {'sections': const {}},
      },
      'USERA',
      '2000-01-01',
    );

    expect(jsonEncode(data.data['marks']), marks);
    expect(jsonEncode(data.data['proctorship']), proctor);
    expect(jsonEncode(data.data['fees']), fees);
    expect(data.data['name'], 'Good profile');
    expect(data.syncStatusFor('proctor'), 'error');
    expect(data.syncStatusFor('fees'), 'error');
    expect(data.syncMetadata['outcome'], 'partial');
    data.dispose();
  });

  test(
    'legacy error payload keeps cached proctor data and error metadata',
    () async {
      final data = SisData();
      await data.applyPortalData(_healthy(), 'USERA', '2000-01-01');
      final previousProctor = jsonEncode(data.data['proctorship']);

      await data.applyPortalData(
        {
          ..._healthy(),
          'proctorship': <dynamic>[],
          '_sync': {
            'sections': {
              'proctor': {'status': 'error', 'failure_reason': 'unknown'},
            },
          },
        },
        'USERA',
        '2000-01-01',
      );

      expect(jsonEncode(data.data['proctorship']), previousProctor);
      expect(data.syncStatusFor('proctor'), 'error');
      expect(
        (data.syncMetadata['sections'] as Map)['proctor']['failure_reason'],
        'unknown',
      );
      data.dispose();
    },
  );

  test(
    'healthy legacy empty-list proctorship is accepted without parse error',
    () async {
      final data = SisData();
      await data.applyPortalData(
        {
          ..._healthy(),
          'proctorship': <dynamic>[],
          'fees': <dynamic>[],
          '_sync': {'sections': const {}},
        },
        'USERA',
        '2000-01-01',
      );

      expect(data.data['proctorship'], isEmpty);
      expect(data.syncStatusFor('proctor'), 'unknown');
      expect(
        ((data.syncMetadata['sections'] as Map)['proctor']
            as Map?)?['failure_reason'],
        isNull,
      );
      expect(data.syncMetadata['outcome'], isNull);
      expect(data.isValidData, isTrue);
      data.dispose();
    },
  );

  test(
    'parse failures persist through a provider restart and stages are reported',
    () async {
      final first = SisData();
      await first.applyPortalData(_healthy(), 'USERA', '2000-01-01');
      final oldMarks = jsonEncode(first.data['marks']);
      final stages = <String>[];
      await first.applyPortalData(
        {
          ..._healthy(),
          'marks': <dynamic>[
            {'bad': true},
          ],
          '_sync': {'sections': const {}},
        },
        'USERA',
        '2000-01-01',
        onStage: stages.add,
      );
      expect(stages, ['parse', 'persist']);
      first.dispose();

      final restored = SisData();
      await pumpEventQueue(times: 30);
      expect(jsonEncode(restored.data['marks']), oldMarks);
      expect(restored.syncStatusFor('marks'), 'error');
      expect(restored.syncMetadata['outcome'], 'partial');
      restored.dispose();
    },
  );

  test(
    'same account with whitespace preserves cache during partial checkpoint',
    () async {
      final data = SisData();
      await data.applyPortalData(_healthy(), 'USERA', '2000-01-01');
      final previousFees = jsonEncode(data.data['fees']);
      final previousAttendance = jsonEncode(data.data['attendance']);

      await data.applyPortalData(
        {
          'marks': [
            {
              'name': 'Data Structures (CS102)',
              'a1': '9',
              'a2': '9',
              't1': '9',
              't2': '9',
              'final cie': '36',
              'class_average': {'a1': '8', 'a2': '8', 't1': '8', 't2': '8'},
            },
          ],
          '_sync': {
            'outcome': 'partial',
            'sections': {
              'marks': {'status': 'partial'},
            },
          },
        },
        ' usera ',
        '2000-01-01',
      );

      expect(data.usn, 'USERA');
      expect(data.data['usn'], 'USERA');
      expect(data.data['name'], 'Student A');
      expect(jsonEncode(data.data['fees']), previousFees);
      expect(jsonEncode(data.data['attendance']), previousAttendance);
      expect(data.data['marks'], hasLength(2));
      expect(data.data['marks'].last['name'], 'Data Structures (CS102)');
      expect((await SharedPreferences.getInstance()).getString('usn'), 'USERA');
      data.dispose();
    },
  );

  test(
    'legacy cache restores saved account ID before same-account partial merge',
    () async {
      SharedPreferences.setMockInitialValues({
        'hasData': true,
        'usn': ' usera ',
        'dob': '2000-01-01',
        'data': jsonEncode({..._healthy(), 'fees': <dynamic>[]}),
        'timeStamp': DateTime.now().millisecondsSinceEpoch,
      });
      final data = SisData();
      await pumpEventQueue(times: 30);
      expect(data.usn, 'USERA');
      expect(data.data['usn'], 'USERA');
      final oldFees = jsonEncode(data.data['fees']);
      final oldMarks = jsonEncode(data.data['marks']);

      await data.applyPortalData(
        {
          'marks': <dynamic>[],
          '_sync': {
            'outcome': 'partial',
            'sections': {
              'marks': {'status': 'partial'},
            },
          },
        },
        ' usera ',
        '2000-01-01',
      );

      expect(data.data['name'], 'Student A');
      expect(jsonEncode(data.data['fees']), oldFees);
      expect(jsonEncode(data.data['marks']), oldMarks);
      expect(data.usn, 'USERA');
      data.dispose();
    },
  );

  test('legacy cache never carries sections into a different saved account', () async {
    SharedPreferences.setMockInitialValues({
      'hasData': true,
      'usn': 'USERA',
      'dob': '2000-01-01',
      'data': jsonEncode({..._healthy(), 'fees': <dynamic>[]}),
      'timeStamp': DateTime.now().millisecondsSinceEpoch,
    });
    final data = SisData();
    await pumpEventQueue(times: 30);

    await data.applyPortalData(
      {'name': 'Student B'},
      ' USERB ',
      '2001-02-02',
    );

    expect(data.usn, 'USERB');
    expect(data.data['usn'], 'USERB');
    expect(data.data['name'], 'Student B');
    expect(data.data['marks'], isNull);
    expect(data.data['fees'], isNull);
    expect(data.data['proctorship'], isNull);
    data.dispose();
  });

  test('unknown legacy cache identity never matches a new account', () async {
    SharedPreferences.setMockInitialValues({
      'hasData': true,
      'data': jsonEncode({..._healthy(), 'fees': <dynamic>[]}),
      'timeStamp': DateTime.now().millisecondsSinceEpoch,
    });
    final data = SisData();
    await pumpEventQueue(times: 30);
    expect(data.usn, isEmpty);

    await data.applyPortalData(
      {'name': 'Student B'},
      'USERB',
      '2001-02-02',
    );

    expect(data.usn, 'USERB');
    expect(data.data['name'], 'Student B');
    expect(data.data['marks'], isNull);
    expect(data.data['fees'], isNull);
    expect(data.data['proctorship'], isNull);
    data.dispose();
  });

  test(
    'switching USN never carries previous account sections forward',
    () async {
      final data = SisData();
      await data.applyPortalData(_healthy(), 'USERA', '2000-01-01');
      await data.applyPortalData(
        {'name': 'Student B'},
        ' USERB ',
        '2001-02-02',
      );

      expect(data.usn, 'USERB');
      expect(data.data['usn'], 'USERB');
      expect(data.data['name'], 'Student B');
      expect(data.data['marks'], isNull);
      expect(data.data['fees'], isNull);
      expect(data.data['proctorship'], isNull);
      data.dispose();
    },
  );

  test(
    'DUMMY cache does not seed sample marks into a real first login',
    () async {
      final data = SisData();
      await data.loadDummyData();
      expect(data.usn.toUpperCase(), 'DUMMY');
      expect(data.marks, isNotEmpty);

      await data.applyPortalData(
        {'name': 'Real Student'},
        'REAL001',
        '2001-02-02',
      );

      expect(data.usn, 'REAL001');
      expect(data.data['name'], 'Real Student');
      expect(data.data['marks'], isNull);
      expect(data.marks, isEmpty);
      data.dispose();
    },
  );
}
