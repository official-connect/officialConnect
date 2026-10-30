import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Services/portal_scraper.dart';
import 'package:official_connect/Services/portal_session.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';

class _FixturePages {
  _FixturePages(this.responses, {this.throwingIds = const {}});

  final Map<String, String> responses;
  final Set<String> throwingIds;

  Future<String> navigateAndRead(Uri uri) async {
    final id = uri.queryParameters['id'];
    if (id != null && throwingIds.contains(id)) {
      throw StateError('simulated section failure');
    }
    if (uri == PortalSession.dashboardUri) return responses['dashboard']!;
    if (uri.toString().contains('attendencelist')) {
      return responses['attendance:$id']!;
    }
    if (uri.toString().contains('ciedetails')) return responses['marks:$id']!;
    if (uri.queryParameters['option'] == 'com_fee') return responses['fees']!;
    if (uri.queryParameters['task'] == 'observation') {
      return responses['proctor']!;
    }
    if (uri.queryParameters['task'] == 'timetable') {
      return responses['timetable']!;
    }
    if (uri.queryParameters['task'] == 'seating') {
      return responses['seating']!;
    }
    if (uri.queryParameters['option'] == 'com_history') {
      return responses['results']!;
    }
    throw StateError('No fixture for $uri');
  }
}

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  tearDown(() => FirebaseFeatureFlags.setValuesForTesting(const {}));

  Map<String, String> fixtures() => {
    'dashboard': _fixture('dashboard_variant.html'),
    'attendance:good': _fixture('attendance_variant.html'),
    'attendance:bad': _fixture('malformed_section.html'),
    'marks:good': _fixture('marks_variant.html'),
    'marks:bad': _fixture('malformed_section.html'),
    'fees': _fixture('fees_variant.html'),
    'proctor': _fixture('proctor_variant.html'),
    'results': _fixture('results_variant.html'),
    'timetable': _fixture('timetable_variant.html'),
    'seating': _fixture('seating_variant.html'),
  };

  test(
    'failure progress identifies the course checkpoint without exposing links',
    () async {
      final pages = _FixturePages(fixtures());
      final steps = <(String, String)>[];
      final scraper = PortalScraper.forTesting(
        navigateAndRead: pages.navigateAndRead,
        onDiagnosticStep: (section, step) => steps.add((section, step)),
        onMarksReady: (_) async =>
            throw const FormatException('private payload'),
      );
      await expectLater(scraper.scrapeAll(), throwsFormatException);
      expect(steps.last, ('marks', 'checkpoint'));
      expect(steps, contains(('attendance', 'navigate')));
      expect(steps, contains(('marks', 'parse')));
      expect(steps.toString(), isNot(contains('private payload')));
      expect(steps.toString(), isNot(contains('https://')));
    },
  );

  test('an unavailable dashboard identifies the navigation stage', () async {
    final steps = <(String, String)>[];
    await expectLater(
      PortalScraper.forTesting(
        navigateAndRead: (_) =>
            Future.error(const PortalSessionExpiredException()),
        onDiagnosticStep: (section, step) => steps.add((section, step)),
      ).scrapeAll(),
      throwsA(isA<PortalSessionExpiredException>()),
    );
    expect(steps.last, ('dashboard', 'navigate'));
  });

  test(
    'fresh marks are delivered before a later course and survive cancellation',
    () async {
      final responses = fixtures();
      responses['marks:bad'] = responses['marks:good']!
          .replaceAll('IS701', 'IS702')
          .replaceAll('Distributed Systems', 'Networks');
      final pages = _FixturePages(responses);
      var active = true;
      final saved = <Map<String, dynamic>>[];
      final scraper = PortalScraper.forTesting(
        navigateAndRead: pages.navigateAndRead,
        isActive: () => active,
        onMarksReady: (data) async {
          saved.add(data);
          active = false;
        },
      );
      await expectLater(scraper.scrapeAll(), throwsStateError);
      expect(saved, hasLength(1));
      expect(saved.single['marks'], hasLength(1));
      expect(saved.single['_sync']['sections']['marks']['status'], 'partial');
      expect(saved.single['_sync']['sections']['proctor']['status'], 'pending');
    },
  );

  test(
    'marks checkpoints are independent snapshots of completed courses',
    () async {
      final responses = fixtures();
      responses['marks:bad'] = responses['marks:good']!
          .replaceAll('IS701', 'IS702')
          .replaceAll('Distributed Systems', 'Networks');
      final pages = _FixturePages(responses);
      final saved = <Map<String, dynamic>>[];
      await PortalScraper.forTesting(
        navigateAndRead: pages.navigateAndRead,
        onMarksReady: (data) async => saved.add(data),
      ).scrapeAll();
      expect(saved, hasLength(2));
      expect(saved.first['marks'], hasLength(1));
      expect(saved.last['marks'], hasLength(2));
    },
  );

  test(
    'attendance is delivered before optional sections and cancellation stops sync',
    () async {
      final pages = _FixturePages(fixtures());
      var active = true;
      var delivered = false;
      final scraper = PortalScraper.forTesting(
        navigateAndRead: pages.navigateAndRead,
        isActive: () => active,
        onAttendanceReady: (data) async {
          delivered = true;
          expect(data['attendance'], hasLength(1));
          expect(data['_sync']['outcome'], 'partial');
          expect(data['_sync']['sections']['timetable']['status'], 'pending');
          active = false;
        },
      );
      await expectLater(scraper.scrapeAll(), throwsStateError);
      expect(delivered, isTrue);
    },
  );

  test(
    'verified fetches are bounded to two and failed pages use navigation',
    () async {
      final responses = fixtures();
      responses['dashboard'] = responses['dashboard']!
          .replaceAll('Attendance A', 'IS701')
          .replaceAll('Attendance B', 'IS702')
          .replaceFirst(
            '</body>',
            '<a href="?task=attendencelist&id=third">IS701</a><a href="?task=attendencelist&id=fourth">IS701</a></body>',
          );
      responses['attendance:third'] = responses['attendance:good']!;
      responses['attendance:fourth'] = responses['attendance:good']!;
      final pages = _FixturePages(responses);
      var activeFetches = 0;
      var maxFetches = 0;
      var fallbackWhileFetching = false;
      final navigationIds = <String?>[];
      final result = await PortalScraper.forTesting(
        navigateAndRead: (uri) async {
          fallbackWhileFetching |= activeFetches > 0;
          navigationIds.add(uri.queryParameters['id']);
          return pages.navigateAndRead(uri);
        },
        fetchHtml: (uri) async {
          activeFetches++;
          if (activeFetches > maxFetches) maxFetches = activeFetches;
          try {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            // Wrong course is rejected even though it has valid structure.
            return responses['attendance:good']!;
          } finally {
            activeFetches--;
          }
        },
      ).scrapeAll();
      expect(maxFetches, 2);
      expect(fallbackWhileFetching, isFalse);
      expect(navigationIds, contains('bad'));
      expect(navigationIds.where((id) => id == 'third'), isEmpty);
      expect(result['attendance'], hasLength(3));
    },
  );

  test(
    'login fetch response disables fast path without losing attendance',
    () async {
      final pages = _FixturePages(fixtures());
      var fetchCount = 0;
      final result = await PortalScraper.forTesting(
        navigateAndRead: pages.navigateAndRead,
        fetchHtml: (_) async {
          fetchCount++;
          return '<input name="username"><input type="password">';
        },
      ).scrapeAll();
      // Attendance + marks probes and one fetch attempt per single-page
      // section (proctor, fees, timetable, seating, results); every login
      // shape is rejected and falls back to navigation.
      expect(fetchCount, 7);
      expect(result['attendance'], hasLength(1));
      expect(result['marks'], hasLength(1));
    },
  );

  test('parses anonymized alternate portal layouts', () async {
    final pages = _FixturePages(fixtures());
    final result = await PortalScraper.forTesting(
      navigateAndRead: pages.navigateAndRead,
    ).scrapeAll();

    expect(result['name'], 'Test Student');
    expect(result['courseSmall'], 'B.E. ISE');
    expect((result['attendance'] as List), hasLength(1));
    expect(result['attendance'][0]['code'], 'IS701');
    expect(result['attendance'][0]['percentage'], '90%');
    expect((result['marks'] as List), hasLength(1));
    expect(result['marks'][0]['final cie'], '91');
    expect((result['fees'] as List), hasLength(1));
    expect((result['prevResults'] as List), hasLength(1));
    expect(result['prevResults'][0]['results'][0]['Grade'], 'A');
    expect((result['timetable'] as List), hasLength(2));
    expect(result['timetable'][0]['room'], 'LAB 5');
    expect((result['seating'] as List), hasLength(1));
    expect(result['seating'][0]['room'], 'AB504');
    expect(result['_sync']['sections']['timetable']['status'], 'ok');
    expect(result['_sync']['sections']['seating']['status'], 'ok');
  });

  test('profile parses the live portal summary shape', () async {
    final responses = fixtures();
    // Live portal shape (Oct 2026): name and summary sit under .cn-stu-data1
    // as h3 + p, with no data-* attributes. Anonymized values.
    responses['dashboard'] = responses['dashboard']!
        .replaceFirst(
          '<section class="student-name" data-student-name>Test Student</section>',
          '<div class="cn-stu-data1"><h3>Test Student</h3>'
              '<p>B.E. ISE, Semester 7, Section A</p></div>',
        )
        .replaceFirst(
          '<p class="student-summary" data-student-summary>B.E. ISE, Semester 7, Section A</p>',
          '',
        );
    final result = await PortalScraper.forTesting(
      navigateAndRead: _FixturePages(responses).navigateAndRead,
    ).scrapeAll();
    expect(result['_sync']['sections']['profile']['status'], 'ok');
    expect(result['courseSmall'], 'B.E. ISE');
    expect(result['sem'], 'Semester 7');
    expect(result['sec'], 'Section A');
  });

  test('one malformed section cannot blank successful sections', () async {
    final pages = _FixturePages(fixtures(), throwingIds: const {'bad'});
    final result = await PortalScraper.forTesting(
      navigateAndRead: pages.navigateAndRead,
    ).scrapeAll();

    expect(result['name'], 'Test Student');
    expect((result['attendance'] as List), hasLength(1));
    expect((result['marks'] as List), hasLength(1));
    expect((result['fees'] as List), hasLength(1));
    expect((result['prevResults'] as List), hasLength(1));
    expect(result['_sync']['outcome'], 'partial');
    expect(result['_sync']['sections']['attendance']['status'], 'partial');
    expect(result['_sync']['sections']['marks']['status'], 'partial');
    expect(
      result['_sync']['sections']['attendance']['failure_reason'],
      'state_error',
    );
  });

  test('disabled sections are skipped without blocking enabled data', () async {
    FirebaseFeatureFlags.setValuesForTesting(const {
      'scraper_attendance_enabled': false,
      'scraper_marks_enabled': false,
    });
    final pages = _FixturePages(fixtures());
    final result = await PortalScraper.forTesting(
      navigateAndRead: pages.navigateAndRead,
    ).scrapeAll();

    expect(result['attendance'], isEmpty);
    expect(result['marks'], isEmpty);
    expect(result['_sync']['sections']['attendance']['status'], 'disabled');
    expect(result['_sync']['sections']['marks']['status'], 'disabled');
    expect((result['fees'] as List), hasLength(1));
    expect((result['prevResults'] as List), hasLength(1));
  });

  test('monday timetable tables parse with their date', () async {
    final values = fixtures();
    values['timetable'] = _fixture('timetable_monday_variant.html');
    final pages = _FixturePages(values);
    final result = await PortalScraper.forTesting(
      navigateAndRead: pages.navigateAndRead,
    ).scrapeAll();

    final timetable = result['timetable'] as List;
    expect(timetable, hasLength(2));
    expect(timetable[0]['day'], 'MONDAY');
    expect(timetable[0]['date'], '2026-09-14');
    expect(result['_sync']['sections']['timetable']['status'], 'ok');
  });

  test('a hung page times out without stalling later sections', () async {
    final values = fixtures();
    final pages = _FixturePages(values);
    Future<String> hangingRead(Uri uri) {
      if (uri.queryParameters['task'] == 'timetable') {
        return Completer<String>().future;
      }
      return pages.navigateAndRead(uri);
    }

    final watch = Stopwatch()..start();
    final result = await PortalScraper.forTesting(
      navigateAndRead: hangingRead,
      pageReadTimeout: const Duration(milliseconds: 50),
    ).scrapeAll();
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
    expect(result['_sync']['sections']['timetable']['status'], 'error');
    expect(
      result['_sync']['sections']['timetable']['failure_reason'],
      'timeout',
    );
    expect(result['_sync']['sections']['seating']['status'], 'ok');
    expect(result['_sync']['outcome'], 'partial');
  });

  test('marks fast path accepts distinct courses without navigation', () async {
    final responses = fixtures();
    responses['dashboard'] = responses['dashboard']!.replaceFirst(
      '</body>',
      '<a href="?task=ciedetails&id=third">CIE C</a></body>',
    );
    responses['marks:third'] = responses['marks:good']!.replaceAll(
      'IS701 - Distributed Systems',
      'IS702 - Operating Systems',
    );
    final pages = _FixturePages(responses);
    final navigated = <Uri>[];
    final result = await PortalScraper.forTesting(
      navigateAndRead: (uri) async {
        navigated.add(uri);
        return pages.navigateAndRead(uri);
      },
      fetchHtml: (uri) async {
        if (uri.toString().contains('ciedetails')) {
          final id = uri.queryParameters['id'];
          if (id == 'bad') return responses['marks:bad']!;
          return responses['marks:$id']!;
        }
        throw StateError('no fetch for $uri');
      },
    ).scrapeAll();
    // The probe page navigates once; the distinct third course is fetched;
    // the malformed page falls back to navigation.
    final marksNavs = navigated
        .where((uri) => uri.toString().contains('ciedetails'))
        .map((uri) => uri.queryParameters['id'])
        .toList();
    expect(marksNavs, containsAll(['good', 'bad']));
    expect(marksNavs, isNot(contains('third')));
    expect(result['marks'], hasLength(2));
    expect(result['_sync']['sections']['marks']['status'], 'ok');
  });

  test('duplicate fetched marks fall back to navigation', () async {
    final responses = fixtures();
    responses['dashboard'] = responses['dashboard']!.replaceFirst(
      '</body>',
      '<a href="?task=ciedetails&id=third">CIE C</a></body>',
    );
    responses['marks:third'] = responses['marks:good']!.replaceAll(
      'IS701 - Distributed Systems',
      'IS702 - Operating Systems',
    );
    final pages = _FixturePages(responses);
    final navigated = <Uri>[];
    final result = await PortalScraper.forTesting(
      navigateAndRead: (uri) async {
        navigated.add(uri);
        return pages.navigateAndRead(uri);
      },
      // Every fetch answers with the probe course: repeats of the probe
      // identity must navigate instead of duplicating it.
      fetchHtml: (uri) async {
        if (uri.toString().contains('ciedetails')) {
          return responses['marks:good']!;
        }
        throw StateError('no fetch for $uri');
      },
    ).scrapeAll();
    final marksNavs = navigated
        .where((uri) => uri.toString().contains('ciedetails'))
        .map((uri) => uri.queryParameters['id'])
        .toList();
    expect(marksNavs, containsAll(['good', 'bad', 'third']));
    expect(result['marks'], hasLength(2));
  });

  test(
    'single-page sections prefer fetch and fall back to navigation',
    () async {
      final responses = fixtures();
      final pages = _FixturePages(responses);
      final navigated = <Uri>[];
      final result = await PortalScraper.forTesting(
        navigateAndRead: (uri) async {
          navigated.add(uri);
          return pages.navigateAndRead(uri);
        },
        fetchHtml: (uri) async {
          final task = uri.queryParameters['task'];
          if (task == 'observation') return responses['proctor']!;
          if (uri.queryParameters['option'] == 'com_fee') {
            return responses['fees']!;
          }
          if (task == 'seating') return responses['seating']!;
          if (uri.queryParameters['option'] == 'com_history') {
            return responses['results']!;
          }
          // Timetable fetch fails: navigation must cover it.
          throw StateError('fetch unavailable');
        },
      ).scrapeAll();
      bool navigatedTask(String task) =>
          navigated.any((uri) => uri.queryParameters['task'] == task);
      expect(navigatedTask('observation'), isFalse);
      expect(navigatedTask('seating'), isFalse);
      expect(navigatedTask('getResult'), isFalse);
      expect(
        navigated.any((uri) => uri.queryParameters['option'] == 'com_fee'),
        isFalse,
      );
      expect(navigatedTask('timetable'), isTrue);
      for (final section in [
        'proctor',
        'fees',
        'timetable',
        'seating',
        'results',
      ]) {
        expect(
          result['_sync']['sections'][section]['status'],
          'ok',
          reason: section,
        );
      }
    },
  );

  test(
    'results read precedes course navigations to preserve the dashboard click',
    () async {
      final responses = fixtures();
      final pages = _FixturePages(responses);
      final navigated = <Uri>[];
      final result = await PortalScraper.forTesting(
        navigateAndRead: (uri) async {
          navigated.add(uri);
          return pages.navigateAndRead(uri);
        },
        // The history fetch serves an empty shell, forcing the navigation
        // fallback; every other fetch is refused outright.
        fetchHtml: (uri) async {
          if (uri.queryParameters['task'] == 'getResult') return '';
          throw StateError('no fetch for $uri');
        },
      ).scrapeAll();
      final historyReads = [
        for (var i = 0; i < navigated.length; i++)
          if (navigated[i].queryParameters['task'] == 'getResult') i,
      ];
      final firstCourseRead = navigated.indexWhere(
        (uri) =>
            uri.toString().contains('attendencelist') ||
            uri.toString().contains('ciedetails'),
      );
      // Direct history-route navigation is answered with the login page;
      // only a dashboard link click reaches it, and course navigations
      // leave the dashboard with no way back — so history must be read
      // before the first course page.
      expect(historyReads, hasLength(1));
      expect(historyReads.single, lessThan(firstCourseRead));
      expect(result['_sync']['sections']['results']['status'], 'ok');
      expect(result['prevResults'], hasLength(1));
    },
  );

  test('dashboard reuses the current page when already loaded', () async {
    final responses = fixtures();
    final pages = _FixturePages(responses);
    final navigated = <Uri>[];
    final result = await PortalScraper.forTesting(
      navigateAndRead: (uri) async {
        navigated.add(uri);
        return pages.navigateAndRead(uri);
      },
      readCurrentDashboard: () async => responses['dashboard'],
    ).scrapeAll();
    // The initial read uses the shortcut, and nothing else navigates to
    // the dashboard (results click from it without revisiting it).
    expect(navigated, isNot(contains(PortalSession.dashboardUri)));
    expect(result['name'], 'Test Student');
    expect(result['attendance'], hasLength(1));
  });

  test('photo download overlaps the attendance scrape', () async {
    final responses = fixtures();
    responses['dashboard'] = responses['dashboard']!.replaceFirst(
      '</body>',
      '<img class="uk-preserve-width uk-border" '
          'src="http://photo.invalid/x.jpg"></body>',
    );
    final pages = _FixturePages(responses);
    final navStarted = Completer<void>();
    var photoStarted = false;
    final result = await PortalScraper.forTesting(
      navigateAndRead: (uri) async {
        if (uri.toString().contains('attendencelist') &&
            !navStarted.isCompleted) {
          navStarted.complete();
        }
        return pages.navigateAndRead(uri);
      },
      // The photo resolves only after an attendance read began: a serial
      // photo-then-attendance implementation would deadlock here.
      fetchDataUri: (_) async {
        photoStarted = true;
        await navStarted.future;
        return 'data:image/jpeg;base64,AAA';
      },
    ).scrapeAll().timeout(const Duration(seconds: 10));
    expect(photoStarted, isTrue);
    expect(result['studentImage'], 'data:image/jpeg;base64,AAA');
    expect(result['attendance'], hasLength(1));
  });

  test(
    'protected profile photos do not escape as unauthenticated URLs',
    () async {
      final responses = fixtures();
      responses['dashboard'] = responses['dashboard']!.replaceFirst(
        '</body>',
        '<img class="uk-preserve-width uk-border" '
            'src="http://photo.invalid/protected.jpg"></body>',
      );
      final pages = _FixturePages(responses);
      final result = await PortalScraper.forTesting(
        navigateAndRead: pages.navigateAndRead,
        fetchDataUri: (_) async => null,
      ).scrapeAll();

      expect(result['studentImage'], isEmpty);
    },
  );

  test(
    'missing course links are structural failures, not empty data',
    () async {
      final values = fixtures();
      values['dashboard'] = values['dashboard']!
          .replaceAll(RegExp(r'<a href="\?task=attendencelist[^<]+</a>'), '')
          .replaceAll(RegExp(r'<a href="\?task=ciedetails[^<]+</a>'), '');
      final pages = _FixturePages(values);

      final result = await PortalScraper.forTesting(
        navigateAndRead: pages.navigateAndRead,
      ).scrapeAll();

      expect(result['_sync']['sections']['attendance']['status'], 'error');
      expect(result['_sync']['sections']['marks']['status'], 'error');
      expect(
        result['_sync']['sections']['attendance']['failure_reason'],
        'missing_links',
      );
      expect(
        result['_sync']['sections']['marks']['failure_reason'],
        'missing_links',
      );
      expect(result['_sync']['outcome'], 'partial');
    },
  );

  test('proctor reports the parsed note count instead of a fixed one', () async {
    final responses = fixtures();
    responses['proctor'] = responses['proctor']!.replaceFirst(
      '</tbody>',
      '<tr><td>02/09/2026</td><td>Office</td><td>Second note</td></tr></tbody>',
    );
    final pages = _FixturePages(responses);
    final result = await PortalScraper.forTesting(
      navigateAndRead: pages.navigateAndRead,
    ).scrapeAll();

    expect(result['_sync']['sections']['proctor']['status'], 'ok');
    expect(result['_sync']['sections']['proctor']['count'], 2);
    expect(result['proctorship']['proctorial_notes'], hasLength(2));
  });

  test('proctor with an empty notes table reports ok with zero notes', () async {
    final responses = fixtures();
    // Live portal shape: caption + header row, empty tbody, no notes published.
    responses['proctor'] =
        '<!doctype html><html><body><h3>Observation</h3>'
        '<h3 class="md-card-head-text">Test Proctor</h3>'
        '<table class="cn-res-table"><caption>Notes</caption>'
        '<thead><tr><th>Date</th><th>From</th><th>Note</th></tr></thead>'
        '<tbody></tbody></table></body></html>';
    final pages = _FixturePages(responses);
    final result = await PortalScraper.forTesting(
      navigateAndRead: pages.navigateAndRead,
    ).scrapeAll();

    expect(result['_sync']['sections']['proctor']['status'], 'ok');
    expect(result['_sync']['sections']['proctor']['count'], 0);
    expect(result['proctorship'], isA<Map>());
    expect(result['proctorship']['proctor_name'], 'Test Proctor');
    expect(result['proctorship']['proctorial_notes'], isEmpty);
  });

  test(
    'proctorship keeps its map shape on failure and disabled paths',
    () async {
      // Failure path: no proctor fixture makes navigation throw.
      final failing = fixtures()..remove('proctor');
      final failed = await PortalScraper.forTesting(
        navigateAndRead: _FixturePages(failing).navigateAndRead,
      ).scrapeAll();
      expect(failed['_sync']['sections']['proctor']['status'], 'error');
      expect(failed['proctorship'], isA<Map>());
      expect(failed['proctorship']['proctorial_notes'], isEmpty);

      // Disabled path.
      FirebaseFeatureFlags.setValuesForTesting(const {
        'scraper_proctor_enabled': false,
      });
      final disabled = await PortalScraper.forTesting(
        navigateAndRead: _FixturePages(fixtures()).navigateAndRead,
      ).scrapeAll();
      expect(disabled['_sync']['sections']['proctor']['status'], 'disabled');
      expect(disabled['proctorship'], isA<Map>());
      expect(disabled['proctorship']['proctorial_notes'], isEmpty);
    },
  );

  test(
    'fees with a header-only table reports empty instead of failing',
    () async {
      final responses = fixtures();
      responses['fees'] =
          '<!doctype html><html><body>'
          '<table class="cn-pay-table"><thead><tr><th>Year</th><th>Paid</th></tr></thead>'
          '<tbody></tbody></table></body></html>';
      final pages = _FixturePages(responses);
      final result = await PortalScraper.forTesting(
        navigateAndRead: pages.navigateAndRead,
      ).scrapeAll();

      expect(result['_sync']['sections']['fees']['status'], 'empty');
      expect(result['fees'], isEmpty);
    },
  );

  test('an empty fee page keeps dashboard fees instead of wiping them', () async {
    final responses = fixtures();
    responses['dashboard'] = responses['dashboard']!.replaceFirst(
      '</body>',
      '<table data-section="fees"><thead><tr><th>Academic Year</th><th>Amount Paid</th></tr></thead>'
          '<tbody><tr><td>2026-27</td><td>1000</td></tr></tbody></table></body>',
    );
    responses['fees'] =
        '<!doctype html><html><body>'
        '<table class="cn-pay-table"><thead><tr><th>Year</th><th>Paid</th></tr></thead>'
        '<tbody></tbody></table></body></html>';
    final pages = _FixturePages(responses);
    final result = await PortalScraper.forTesting(
      navigateAndRead: pages.navigateAndRead,
    ).scrapeAll();

    expect(result['_sync']['sections']['fees']['status'], 'ok');
    expect(result['fees'], hasLength(1));
  });

  test('proctor header splits name, department, email and phone', () async {
    final responses = fixtures();
    // Live portal shape: bare name text node, then department, email and
    // phone each in their own span.
    responses['proctor'] =
        '<!doctype html><html><body>'
        '<h3 class="md-card-head-text">Test Proctor '
        '<span>Test Department</span> '
        '<span>proctor@example.edu</span> '
        '<span>9999999999</span></h3>'
        '<table class="cn-res-table"><tbody></tbody></table></body></html>';
    final pages = _FixturePages(responses);
    final result = await PortalScraper.forTesting(
      navigateAndRead: pages.navigateAndRead,
    ).scrapeAll();

    final proctorship = result['proctorship'] as Map;
    expect(proctorship['proctor_name'], 'Test Proctor');
    expect(proctorship['branch'], 'Test Department');
    expect(proctorship['email'], 'proctor@example.edu');
    expect(proctorship['phone'], '9999999999');
    expect(result['_sync']['sections']['proctor']['count'], 0);
  });
}
