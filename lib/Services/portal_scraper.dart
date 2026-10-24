import 'dart:async';
import 'dart:convert';
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart';
import 'package:official_connect/Services/portal_session.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/firebase_performance_traces.dart';

/// Parses the portal's authenticated HTML into the JSON shape used by the
/// existing Flutter models. Requests are made with the WebView session cookie.
class PortalScraper {
  PortalScraper(
    PortalSession session, {
    this.onProgress,
    this.onAttendanceReady,
    this.isActive,
  }) : _navigateAndRead = session.navigateAndRead,
       _fetchHtml = ((uri) => session.fetchHtml(
         uri,
         timeout: const Duration(seconds: 3),
         preserveHref: true,
       )),
       _fetchDataUri = session.fetchDataUri,
       _readCurrentDashboard = session.currentDashboardHtml,
       pageReadTimeout = const Duration(seconds: 40);

  /// Allows fixture tests to exercise the complete scrape without creating a
  /// native WebView. Production callers should use [PortalScraper.new].
  PortalScraper.forTesting({
    required Future<String> Function(Uri uri) navigateAndRead,
    Future<String?> Function(Uri uri)? fetchDataUri,
    Future<String> Function(Uri uri)? fetchHtml,
    Future<String?> Function()? readCurrentDashboard,
    this.onProgress,
    this.onAttendanceReady,
    this.isActive,
    this.pageReadTimeout = const Duration(seconds: 40),
  }) : _navigateAndRead = navigateAndRead,
       _fetchHtml = fetchHtml,
       _fetchDataUri = fetchDataUri ?? ((_) async => null),
       _readCurrentDashboard = readCurrentDashboard;

  /// Reads one portal page, failing fast with a `timeout` failure reason
  /// instead of hanging the sections queued behind it. Section catch blocks
  /// already map this to `failure_reason: 'timeout'` and continue, so the
  /// refresh degrades to cached data per section rather than stalling whole.
  Future<String> _readPage(Uri uri) async {
    _checkActive();
    try {
      return await _navigateAndRead(uri).timeout(pageReadTimeout);
    } on TimeoutException {
      throw PortalRequestException(uri, 'page read timed out');
    }
  }

  final Future<String> Function(Uri uri) _navigateAndRead;
  final Future<String> Function(Uri uri)? _fetchHtml;
  final Future<String?> Function(Uri uri) _fetchDataUri;
  final Future<String?> Function()? _readCurrentDashboard;
  final void Function(String stage)? onProgress;
  final Future<void> Function(Map<String, dynamic> data)? onAttendanceReady;
  final bool Function()? isActive;

  void _checkActive() {
    if (isActive?.call() == false) throw StateError('Portal sync cancelled');
  }

  String _courseLinkLabel(Element anchor) {
    Element? parent = anchor.parent;
    while (parent != null && parent.localName != 'body') {
      if (parent.localName == 'tr') return parent.text;
      parent = parent.parent;
    }
    return anchor.text;
  }

  /// Reads the link-discovery dashboard. A fresh login always lands on it,
  /// so the current page is usually reused directly instead of reloading.
  Future<String> _readDashboard() async {
    _checkActive();
    final shortcut = _readCurrentDashboard;
    if (shortcut != null) {
      try {
        final html = await shortcut();
        if (html != null) return html;
      } catch (_) {
        // Fall through to navigation below.
      }
    }
    return _readPage(PortalSession.dashboardUri);
  }

  /// Reads a single-page section through the background fetch when the
  /// portal serves its full content that way, falling back to a real
  /// navigation otherwise. Any fetch failure (timeout, login redirect,
  /// unexpected shape) silently uses navigation, so the outcome matches
  /// [_readPage] exactly — only faster when the fetch suffices.
  Future<Document> _readSinglePage(
    Uri uri,
    bool Function(Document doc) hasStructure,
  ) async {
    final fetch = _fetchHtml;
    if (fetch != null) {
      try {
        final doc = parser.parse(await fetch(uri));
        if (doc.querySelector(
                  'input[name="username"], input[type="password"]',
                ) ==
                null &&
            hasStructure(doc)) {
          return doc;
        }
      } catch (_) {
        // Fall through to navigation below.
      }
    }
    return parser.parse(await _readPage(uri));
  }

  /// Semester results via background fetch when the portal serves the table
  /// directly, else a dashboard link click. Direct navigation to the history
  /// route is answered with the login page — only a real EXAM HISTORY click
  /// reaches the signed history destination — so the results section runs
  /// before any other navigation, while the browser still shows the
  /// dashboard, and this fallback lets [PortalSession.navigateAndRead]
  /// click it. Do not call this after course navigations have left the
  /// dashboard: there is no way back (unsigned dashboard navigation is
  /// refused the same way) and the click would silently become one.
  Future<Document> _readResultsPage(Uri uri) async {
    final fetch = _fetchHtml;
    if (fetch != null) {
      try {
        final doc = parser.parse(await fetch(uri));
        if (_parsePreviousResults(doc).isNotEmpty) return doc;
      } catch (_) {
        // Fall through to the dashboard click below.
      }
    }
    return parser.parse(await _readPage(uri));
  }

  // Probe against navigation on every refresh. Only verifiable course pages
  // use the fast path; the rest retain serialized navigation. Attendance
  // matches each fetched page against its dashboard link label; marks pages
  // carry no dashboard-matchable identity, so they are accepted when they
  // parse to a distinct course (a fetch that returned one shared page for
  // every URL would collapse to a single identity and fall back).
  Future<List<String?>> _coursePages(
    List<Uri> links,
    Document dashboard, {
    required String sectionLabel,
    required Map<String, dynamic> Function(Document doc) parseCourse,
    required bool Function(Document doc) hasCourseStructure,
    required String Function(Map<String, dynamic> course) courseIdentity,
    bool Function(String identity, String labels)? labelMatches,
  }) async {
    final pages = List<String?>.filled(links.length, null);
    if (links.isEmpty || _fetchHtml == null) return pages;
    // Identities accepted so far, starting with the navigation-verified
    // probe page. Guards the no-label fast path against a fetch endpoint
    // that answers every course URL with the same page.
    final seenIdentities = <String>{};
    try {
      final fetched = await _fetchHtml(links.first);
      final navigated = await _readPage(links.first);
      pages[0] = navigated;
      final probeCourse = parseCourse(parser.parse(fetched));
      if (!hasCourseStructure(parser.parse(fetched)) ||
          jsonEncode(probeCourse) !=
              jsonEncode(parseCourse(parser.parse(navigated)))) {
        onProgress?.call('Using standard $sectionLabel sync');
        return pages;
      }
      seenIdentities.add(courseIdentity(probeCourse));
      onProgress?.call('Background $sectionLabel fetch verified');
      // Fetch in pairs, and finish both before any fallback navigation.
      // Validation runs sequentially after each pair so identity checks
      // observe every previously accepted page.
      for (var start = 1; start < links.length; start += 2) {
        _checkActive();
        final fetchedPair = await Future.wait([
          for (
            var index = start;
            index < links.length && index < start + 2;
            index++
          )
            (() async {
              try {
                return (index, await _fetchHtml(links[index]));
              } catch (_) {
                // Failed fetches are retried by ordinary navigation below.
                return (index, null);
              }
            })(),
        ]);
        for (final (index, html) in fetchedPair) {
          if (html == null) continue;
          final page = parser.parse(html);
          final identity = courseIdentity(parseCourse(page));
          var matches = identity.isNotEmpty;
          var identityClaimed = false;
          if (matches) {
            if (labelMatches != null) {
              final labels = _clean(
                dashboard
                    .querySelectorAll('a[href]')
                    .where(
                      (a) =>
                          PortalSession.loginUri.resolve(
                            a.attributes['href']!,
                          ) ==
                          links[index],
                    )
                    .map(_courseLinkLabel)
                    .join(' '),
              );
              matches = labelMatches(identity, labels);
            } else {
              matches = seenIdentities.add(identity);
              identityClaimed = matches;
            }
          }
          if (page.querySelector(
                    'input[name="username"], input[type="password"]',
                  ) ==
                  null &&
              hasCourseStructure(page) &&
              matches) {
            pages[index] = html;
          } else if (identityClaimed) {
            // A structurally rejected page must not poison the identity
            // set for a later retry of the same course.
            seenIdentities.remove(identity);
          }
        }
      }
      onProgress?.call(
        'Background $sectionLabel accepted ${pages.skip(1).whereType<String>().length}/${links.length - 1} pages',
      );
    } catch (_) {
      onProgress?.call('Using standard $sectionLabel sync');
    }
    return pages;
  }

  /// Upper bound for a single portal page read inside [scrapeAll].
  ///
  /// The WebView bridge calls in `PortalSession.navigateAndRead` have no
  /// timeout of their own, so without this cap one hung page on slow wifi
  /// stalls every section behind it until the 90s refresh budget expires.
  /// 40s covers the worst legitimate case (~15s navigation polling + ~6s
  /// content wait + bridge overhead). Reviewed 2026-10-02 against 7d of
  /// fleet data: healthy reads take ~0.5-1.5s, timeouts (~1%) are fixed
  /// pathologies plus backgrounded sessions, so the 40s hang protection
  /// stays; the duration_bucket dimension (once registered) enables a
  /// future p99-based trim.
  final Duration pageReadTimeout;

  Future<Map<String, dynamic>> scrapeAll() async {
    final syncWatch = Stopwatch()..start();
    final sections = <String, dynamic>{};
    // Overall sync trace; a throw before the matching stop simply drops it.
    unawaited(FirebasePerformanceTraces.startPortalSync());
    void recordSection(
      String name,
      String status, {
      int count = 0,
      int attempted = 0,
      int failed = 0,
      int durationMs = 0,
      String? failureReason,
    }) {
      sections[name] = {
        'status': status,
        'count': count,
        'attempted': attempted,
        'failed': failed,
        'duration_ms': durationMs,
        if (failureReason != null) 'failure_reason': failureReason,
      };
      // Single choke point for section completion: stops the matching
      // performance trace (no-op when disabled or never started).
      unawaited(
        FirebasePerformanceTraces.stopSection(
          name,
          status: status,
          count: count,
        ),
      );
    }

    onProgress?.call('Reading your profile');
    // A previous sync normally leaves the browser on result history. Always
    // return to the signed dashboard so refreshes rediscover every current
    // attendance, CIE, fee and history link before scraping.
    final dashboard = await _readDashboard();
    final document = parser.parse(dashboard);
    final result = <String, dynamic>{};
    final profileWatch = Stopwatch()..start();
    unawaited(FirebasePerformanceTraces.startSection('profile'));
    if (FirebaseFeatureFlags.sectionEnabled('profile')) {
      _parseStudentSummary(document, result);
    }
    if (FirebaseFeatureFlags.sectionEnabled('fees')) {
      _parseFees(document, result);
    }
    // The portal serves the student photo only to its authenticated browser
    // session, so plain HTTP image loading in the UI fails. Download it here
    // through the WebView and store a self-contained data URI instead. The
    // download starts now but is awaited after the attendance scrape, so it
    // overlaps the course reads instead of delaying them.
    final studentImageUrl = result['studentImage']?.toString();
    final Future<String?>? pendingPhoto =
        studentImageUrl != null && studentImageUrl.startsWith('http')
        ? _fetchDataUri(
            Uri.parse(studentImageUrl),
          ).then((dataUri) => dataUri, onError: (_) => null)
        : null;
    final profileValues = [
      result['name'],
      result['courseSmall'],
      result['sem'],
    ];
    final profileCount = profileValues
        .where((value) => value?.toString().trim().isNotEmpty == true)
        .length;
    recordSection(
      'profile',
      !FirebaseFeatureFlags.sectionEnabled('profile')
          ? 'disabled'
          : profileCount == profileValues.length
          ? 'ok'
          : profileCount == 0
          ? 'error'
          : 'partial',
      count: profileCount,
      attempted: profileValues.length,
      failed: profileValues.length - profileCount,
      durationMs: profileWatch.elapsedMilliseconds,
      failureReason: profileCount == profileValues.length
          ? null
          : 'missing_fields',
    );

    final links = document
        .querySelectorAll('a[href]')
        .map((e) => e.attributes['href'] ?? '')
        .where((href) => href.isNotEmpty)
        .map((href) => PortalSession.loginUri.resolve(href))
        .toSet();
    final attendanceLinks = FirebaseFeatureFlags.sectionEnabled('attendance')
        ? links.where((u) => u.toString().contains('attendencelist')).toList()
        : <Uri>[];
    final marksLinks = FirebaseFeatureFlags.sectionEnabled('marks')
        ? links.where((u) => u.toString().contains('ciedetails')).toList()
        : <Uri>[];
    final timetableLinks = links
        .where((u) => u.queryParameters['task'] == 'timetable')
        .toList();
    final seatingLinks = links
        .where((u) => u.queryParameters['task'] == 'seating')
        .toList();

    // Semester results run before any course navigation, while the browser
    // still shows the dashboard: the history route is answered with the
    // login page unless it is followed as a real EXAM HISTORY link click,
    // and the click is only possible from the dashboard. (Live browser
    // evidence also disproved the old "result endpoint initializes slowly"
    // theory — tables appear in the first observation after a proper
    // click — so reading results first costs nothing but its own page.)
    final resultLink = links.firstWhere(
      (uri) => uri.queryParameters['task'] == 'getResult',
      orElse: () => Uri.parse(
        'https://parents.msrit.edu/newparents/index.php?option=com_history&task=getResult',
      ),
    );
    if (FirebaseFeatureFlags.sectionEnabled('results')) {
      onProgress?.call('Syncing semester results');
    }
    final resultsWatch = Stopwatch()..start();
    unawaited(FirebasePerformanceTraces.startSection('results'));
    Document? resultsDocument;
    try {
      if (!FirebaseFeatureFlags.sectionEnabled('results')) {
        result['prevResults'] = <dynamic>[];
        recordSection('results', 'disabled');
      } else {
        resultsDocument = await _readResultsPage(resultLink);
        result['prevResults'] = _parsePreviousResults(resultsDocument);
        final count = (result['prevResults'] as List).length;
        recordSection(
          'results',
          count == 0 ? 'empty' : 'ok',
          count: count,
          attempted: 1,
          durationMs: resultsWatch.elapsedMilliseconds,
        );
      }
    } catch (error) {
      result['prevResults'] = <dynamic>[];
      recordSection(
        'results',
        'error',
        attempted: 1,
        failed: 1,
        durationMs: resultsWatch.elapsedMilliseconds,
        failureReason: portalFailureReason(error),
      );
    }

    final attendance = <Map<String, dynamic>>[];
    var attendanceFailures = 0;
    String? attendanceFailureReason;
    var invalidAttendancePages = 0;
    final attendanceWatch = Stopwatch()..start();
    unawaited(FirebasePerformanceTraces.startSection('attendance'));
    if (attendanceLinks.isNotEmpty) {
      onProgress?.call('Syncing attendance');
    }
    final attendancePages = await _coursePages(
      attendanceLinks,
      document,
      sectionLabel: 'attendance',
      parseCourse: _parseAttendance,
      hasCourseStructure: _hasAttendanceStructure,
      courseIdentity: (course) => _clean(course['code']?.toString() ?? ''),
      labelMatches: (identity, labels) =>
          identity.isNotEmpty &&
          RegExp(
            '(^|[^a-z0-9])${RegExp.escape(identity)}([^a-z0-9]|\$)',
            caseSensitive: false,
          ).hasMatch(labels),
    );
    for (var index = 0; index < attendanceLinks.length; index++) {
      final uri = attendanceLinks[index];
      _checkActive();
      try {
        final attendanceDocument = parser.parse(
          attendancePages[index] ?? await _readPage(uri),
        );
        final item = _parseAttendance(attendanceDocument);
        if (_hasCourseIdentity('${item['code']} ${item['name']}') &&
            _hasAttendanceStructure(attendanceDocument)) {
          attendance.add(item);
        } else {
          invalidAttendancePages++;
        }
      } catch (error) {
        attendanceFailures++;
        attendanceFailureReason = portalFailureReason(error);
      }
    }
    attendanceWatch.stop();
    // An enabled dashboard with no discoverable course links is not proof that
    // the student has no attendance. It more commonly means the portal changed
    // its link shape, so flag it and let the cache layer preserve known data.
    if (attendanceLinks.isEmpty &&
        FirebaseFeatureFlags.sectionEnabled('attendance')) {
      attendanceFailures++;
      attendanceFailureReason = 'missing_links';
    }
    // The current portal appends one intentionally blank link. Ignore that
    // shell when valid courses exist, but flag empty/extra invalid pages.
    attendanceFailures += attendance.isEmpty
        ? invalidAttendancePages
        : (invalidAttendancePages - 1).clamp(0, invalidAttendancePages);
    if (invalidAttendancePages > 0 && attendanceFailureReason == null) {
      attendanceFailureReason = 'invalid_content';
    }
    // Collect the photo download that ran concurrently with the course reads
    // above, so both the early and the final payload keep the data URI. A
    // protected or temporarily unavailable photo must never prevent the
    // rest of the student's data from being returned.
    if (pendingPhoto != null) {
      try {
        final dataUri = await pendingPhoto;
        if (dataUri != null) {
          result['studentImage'] = dataUri;
        } else {
          // This resource needs the authenticated browser session. Never
          // leave a protected URL for the native image cache to retry.
          // An explicit empty value is intentional: the cache merger keeps
          // omitted profile fields, so a stale protected URL would otherwise
          // survive a successful refresh.
          result['studentImage'] = '';
        }
      } catch (_) {}
    }
    result['attendance'] = attendance;
    recordSection(
      'attendance',
      !FirebaseFeatureFlags.sectionEnabled('attendance')
          ? 'disabled'
          : _sectionStatus(
              attendanceLinks.length,
              attendance.length,
              attendanceFailures,
            ),
      count: attendance.length,
      attempted: attendanceLinks.length,
      failed: attendanceFailures,
      durationMs: attendanceWatch.elapsedMilliseconds,
      failureReason: attendanceFailures > 0 ? attendanceFailureReason : null,
    );
    _checkActive();
    if (attendance.isNotEmpty && onAttendanceReady != null) {
      await onAttendanceReady!({
        'attendance': attendance,
        '_sync': {
          'version': 1,
          'outcome': 'partial',
          'duration_ms': syncWatch.elapsedMilliseconds,
          'sections': {
            'attendance': sections['attendance'],
            // Results run before attendance (dashboard click), so their
            // real outcome is already known here.
            'results': sections['results'],
            for (final name in [
              'marks',
              'fees',
              'proctor',
              'timetable',
              'seating',
            ])
              name: {'status': 'pending'},
          },
        },
      });
    }

    final marks = <Map<String, dynamic>>[];
    _checkActive();
    var marksFailures = 0;
    String? marksFailureReason;
    var invalidMarksPages = 0;
    final marksWatch = Stopwatch()..start();
    unawaited(FirebasePerformanceTraces.startSection('marks'));
    if (marksLinks.isNotEmpty) onProgress?.call('Syncing internal marks');
    final marksPages = await _coursePages(
      marksLinks,
      document,
      sectionLabel: 'marks',
      parseCourse: _parseMarks,
      hasCourseStructure: (doc) =>
          _hasCourseIdentity(_parseMarks(doc)['name'].toString()) &&
          _marksCells(doc).isNotEmpty,
      courseIdentity: (course) =>
          _clean(course['name']?.toString() ?? '').toLowerCase(),
    );
    for (var index = 0; index < marksLinks.length; index++) {
      final uri = marksLinks[index];
      _checkActive();
      try {
        final marksDocument = parser.parse(
          marksPages[index] ?? await _readPage(uri),
        );
        final item = _parseMarks(marksDocument);
        if (_hasCourseIdentity(item['name'].toString()) &&
            _marksCells(marksDocument).isNotEmpty) {
          marks.add(item);
        } else {
          invalidMarksPages++;
        }
      } catch (error) {
        marksFailures++;
        marksFailureReason = portalFailureReason(error);
      }
    }
    marksWatch.stop();
    // As with attendance, missing dashboard links are a structural discovery
    // failure rather than an authoritative empty marks response.
    if (marksLinks.isEmpty && FirebaseFeatureFlags.sectionEnabled('marks')) {
      marksFailures++;
      marksFailureReason = 'missing_links';
    }
    marksFailures += marks.isEmpty
        ? invalidMarksPages
        : (invalidMarksPages - 1).clamp(0, invalidMarksPages);
    if (invalidMarksPages > 0 && marksFailureReason == null) {
      marksFailureReason = 'invalid_content';
    }
    // The dashboard can include a trailing empty attendance/CIE link. It
    // resolves to a valid page shell, but has no course identity and must not
    // become a blank subject card in the native UI.
    result['marks'] = marks;
    recordSection(
      'marks',
      !FirebaseFeatureFlags.sectionEnabled('marks')
          ? 'disabled'
          : _sectionStatus(marksLinks.length, marks.length, marksFailures),
      count: marks.length,
      attempted: marksLinks.length,
      failed: marksFailures,
      durationMs: marksWatch.elapsedMilliseconds,
      failureReason: marksFailures > 0 ? marksFailureReason : null,
    );

    Uri matchingLink(String fragment, Uri fallback) => links.firstWhere(
      (uri) => uri.toString().contains(fragment),
      orElse: () => fallback,
    );
    if (FirebaseFeatureFlags.sectionEnabled('proctor')) {
      onProgress?.call('Syncing proctor updates');
    }
    final proctorWatch = Stopwatch()..start();
    unawaited(FirebasePerformanceTraces.startSection('proctor'));
    Document? proctorDocument;
    try {
      if (!FirebaseFeatureFlags.sectionEnabled('proctor')) {
        result['proctorship'] = _emptyProctor();
        recordSection('proctor', 'disabled');
      } else {
        proctorDocument = await _readSinglePage(
          matchingLink(
            'task=observation',
            Uri.parse(
              'https://parents.msrit.edu/newparents/index.php?option=com_studentdashboard&controller=studentdashboard&task=observation',
            ),
          ),
          (doc) =>
              doc.querySelector('table.cn-res-table, .md-card-head-text') !=
              null,
        );
        final proctorData = _parseProctor(proctorDocument);
        result['proctorship'] = proctorData;
        recordSection(
          'proctor',
          'ok',
          count: (proctorData['proctorial_notes'] as List).length,
          attempted: 1,
          durationMs: proctorWatch.elapsedMilliseconds,
        );
      }
    } catch (error) {
      result['proctorship'] = _emptyProctor();
      recordSection(
        'proctor',
        'error',
        attempted: 1,
        failed: 1,
        durationMs: proctorWatch.elapsedMilliseconds,
        failureReason: portalFailureReason(error),
      );
    }

    final feeLink = links.where(
      (uri) => uri.queryParameters['option'] == 'com_fee',
    );
    if (!FirebaseFeatureFlags.sectionEnabled('fees')) {
      recordSection('fees', 'disabled');
    } else if (feeLink.isNotEmpty) {
      onProgress?.call('Syncing fee history');
      final feeWatch = Stopwatch()..start();
      unawaited(FirebasePerformanceTraces.startSection('fees'));
      try {
        final feeDocument = await _readSinglePage(
          feeLink.first,
          (doc) =>
              doc.querySelector(
                'table.cn-pay-table, table[data-section="fees"], '
                'table[data-section="refunds"]',
              ) !=
              null,
        );
        final dashboardFees = (result['fees'] as List?) ?? [];
        final dashboardRefunds = (result['refunds'] as List?) ?? [];
        _parseFees(feeDocument, result);
        // An empty fee page must not wipe fees already read from the
        // dashboard: keep the dashboard rows when the page yields nothing.
        if ((result['fees'] as List?)?.isEmpty != false &&
            (result['refunds'] as List?)?.isEmpty != false &&
            (dashboardFees.isNotEmpty || dashboardRefunds.isNotEmpty)) {
          result['fees'] = dashboardFees;
          result['refunds'] = dashboardRefunds;
        }
        final feeCount = (result['fees'] as List?)?.length ?? 0;
        recordSection(
          'fees',
          feeCount == 0 ? 'empty' : 'ok',
          count: feeCount,
          attempted: 1,
          durationMs: feeWatch.elapsedMilliseconds,
        );
      } catch (error) {
        final dashboardFeeCount = (result['fees'] as List?)?.length ?? 0;
        recordSection(
          'fees',
          dashboardFeeCount > 0 ? 'partial' : 'error',
          count: dashboardFeeCount,
          attempted: 1,
          failed: 1,
          durationMs: feeWatch.elapsedMilliseconds,
          failureReason: portalFailureReason(error),
        );
      }
    } else {
      recordSection(
        'fees',
        (result['fees'] as List?)?.isNotEmpty == true ? 'ok' : 'empty',
        count: (result['fees'] as List?)?.length ?? 0,
      );
    }

    final timetableWatch = Stopwatch()..start();
    unawaited(FirebasePerformanceTraces.startSection('timetable'));
    if (!FirebaseFeatureFlags.sectionEnabled('timetable')) {
      result['timetable'] = <dynamic>[];
      recordSection('timetable', 'disabled');
    } else if (timetableLinks.isEmpty) {
      result['timetable'] = <dynamic>[];
      recordSection(
        'timetable',
        'error',
        attempted: 1,
        failed: 1,
        failureReason: 'missing_links',
      );
    } else {
      onProgress?.call('Syncing timetable');
      try {
        final timetableDocument = await _readSinglePage(
          timetableLinks.first,
          (doc) => _parseTimetable(doc).isNotEmpty,
        );
        result['timetable'] = _parseTimetable(timetableDocument);
        final count = (result['timetable'] as List).length;
        recordSection(
          'timetable',
          count == 0 ? 'empty' : 'ok',
          count: count,
          attempted: 1,
          durationMs: timetableWatch.elapsedMilliseconds,
        );
      } catch (error) {
        result['timetable'] = <dynamic>[];
        recordSection(
          'timetable',
          'error',
          attempted: 1,
          failed: 1,
          durationMs: timetableWatch.elapsedMilliseconds,
          failureReason: portalFailureReason(error),
        );
      }
    }

    final seatingWatch = Stopwatch()..start();
    unawaited(FirebasePerformanceTraces.startSection('seating'));
    if (!FirebaseFeatureFlags.sectionEnabled('seating')) {
      result['seating'] = <dynamic>[];
      recordSection('seating', 'disabled');
    } else if (seatingLinks.isEmpty) {
      // Seating is absent outside exam periods, so a missing dashboard link is
      // an authoritative empty state rather than a structural failure.
      result['seating'] = <dynamic>[];
      recordSection('seating', 'empty');
    } else {
      onProgress?.call('Syncing exam seating');
      try {
        final seatingDocument = await _readSinglePage(
          seatingLinks.first,
          (doc) => _parseSeating(doc).isNotEmpty,
        );
        result['seating'] = _parseSeating(seatingDocument);
        final count = (result['seating'] as List).length;
        recordSection(
          'seating',
          count == 0 ? 'empty' : 'ok',
          count: count,
          attempted: 1,
          durationMs: seatingWatch.elapsedMilliseconds,
        );
      } catch (error) {
        result['seating'] = <dynamic>[];
        recordSection(
          'seating',
          'error',
          attempted: 1,
          failed: 1,
          durationMs: seatingWatch.elapsedMilliseconds,
          failureReason: portalFailureReason(error),
        );
      }
    }

    syncWatch.stop();
    final statuses = sections.values
        .whereType<Map>()
        .map((section) => section['status'])
        .toList();
    final syncOutcome =
        statuses.any((status) => status == 'error' || status == 'partial')
        ? 'partial'
        : 'complete';
    result['_sync'] = {
      'version': 1,
      'outcome': syncOutcome,
      'duration_ms': syncWatch.elapsedMilliseconds,
      'sections': sections,
    };
    unawaited(FirebasePerformanceTraces.stopPortalSync(status: syncOutcome));
    assert(() {
      // ignore: avoid_print
      print(
        'Portal detail pages: '
        'resultTables=${resultsDocument?.querySelectorAll('table.res-table').length ?? 0}, '
        'proctorRows=${proctorDocument?.querySelectorAll('table.cn-res-table tbody tr').length ?? 0}',
      );
      return true;
    }());
    return result;
  }

  String _sectionStatus(int attempted, int count, int failed) {
    if (failed > 0 && count > 0) return 'partial';
    if (failed > 0) return 'error';
    if (attempted == 0 || count == 0) return 'empty';
    return 'ok';
  }

  bool _hasCourseIdentity(String value) =>
      value.replaceAll(RegExp(r'[\s()\-]'), '').isNotEmpty;

  bool _hasAttendanceStructure(Document document) =>
      _attendanceCounts(document).length >= 2;

  String _clean(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

  String _label(String value) =>
      _clean(value).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  List<String> _attendanceCounts(Document doc) {
    final legend = doc.querySelector(
      '.cn-legend, [data-section="attendance-summary"]',
    );
    if (legend == null) return const [];
    final bracketed = RegExp(r'\[\s*(\d*)\s*\]')
        .allMatches(legend.text)
        .map((match) => match.group(1)!.isEmpty ? '0' : match.group(1)!)
        .toList();
    if (bracketed.length >= 2) return bracketed;

    String countFor(String name) {
      final element = legend.querySelector('[data-count="$name"]');
      final source = element?.text ?? legend.text;
      return RegExp(
            '$name\\s*[:=-]?\\s*(\\d+)',
            caseSensitive: false,
          ).firstMatch(source)?.group(1) ??
          '0';
    }

    final labelled = ['present', 'absent', 'remaining'].map(countFor).toList();
    return labelled.take(2).every((value) => value == '0') &&
            !RegExp(
              r'present|absent',
              caseSensitive: false,
            ).hasMatch(legend.text)
        ? const []
        : labelled;
  }

  void _parseStudentSummary(Document doc, Map<String, dynamic> out) {
    final name = doc
        .querySelector('.cn-stu-data1 h3, [data-student-name], .student-name')
        ?.text
        .trim();
    if (name != null && name.isNotEmpty) out['name'] = name;
    final summary =
        doc
            .querySelector(
              '.cn-stu-data p, .cn-stu-data1 p, [data-student-summary], .student-summary',
            )
            ?.text
            .split(',')
            .map((x) => x.trim())
            .toList() ??
        [];
    if (summary.length >= 3) {
      out['courseSmall'] = summary[0];
      out['sem'] = summary[1];
      out['sec'] = summary[2];
    }
    final legend = doc
        .querySelectorAll('.cn-legend span')
        .map((e) => e.text.trim())
        .toList();
    if (legend.length >= 2) {
      out['earned'] = legend[0].split(' ').first;
      out['to_earn'] = legend[1].split(' ').first;
    }
    final details = doc.querySelectorAll(
      '.cn-basic-details table tr, [data-section="student-details"] tr',
    );
    for (final row in details) {
      final cells = row.querySelectorAll('td');
      if (cells.length >= 2) out[cells[0].text.trim()] = cells[1].text.trim();
    }
    // Student profile photo (the portal page may hold several images with
    // this class; the last one is the student photo, matching the old
    // previous parser behaviour).
    final images = doc.querySelectorAll('img.uk-preserve-width.uk-border');
    final imgSrc = images.isEmpty ? null : images.last.attributes['src'];
    if (imgSrc != null && imgSrc.trim().isNotEmpty) {
      final src = imgSrc.trim();
      out['studentImage'] = src.startsWith('http')
          ? src
          : 'https://parents.msrit.edu/newparents/$src';
    }
  }

  void _parseFees(Document doc, Map<String, dynamic> out) {
    final fees = <Map<String, String>>[];
    final refunds = <Map<String, String>>[];
    final tables = doc.querySelectorAll(
      'table.cn-pay-table, table[data-section="fees"], table[data-section="refunds"]',
    );
    if (tables.isEmpty) return;
    for (final table in tables) {
      final headers = table
          .querySelectorAll('thead th, thead td')
          .map((e) => e.text.replaceAll(RegExp(r'\s+'), ' ').trim())
          .toList();
      final caption = _label(table.querySelector('caption')?.text ?? '');
      final target =
          (caption.contains('refund') ||
              table.attributes['data-section'] == 'refunds')
          ? refunds
          : fees;
      for (final row in table.querySelectorAll('tbody tr')) {
        final values = row
            .querySelectorAll('td')
            .map((e) => e.text.trim())
            .toList();
        final parsed = <String, String>{
          'Academic Year': '',
          'Amount Paid': '',
          'Challan No': '',
          'Cheque/DD No': '',
          'Date': '',
          'Mode': '',
          'Paid for Year': '',
          'Pay At': '',
          // The current portal no longer emits this legacy column, but the
          // existing native model still expects a non-null value.
          'Receipt': '',
          for (var i = 0; i < values.length && i < headers.length; i++)
            headers[i]: values[i],
        };
        target.add(parsed);
      }
    }
    out['fees'] = fees;
    out['refunds'] = refunds;
  }

  Map<String, dynamic> _parseAttendance(Document doc) {
    final heading = doc.querySelector(
      'h3.md-card-head-text, [data-course-title], .course-title',
    );
    final details =
        (heading?.querySelectorAll('span').isNotEmpty == true
                ? heading!.querySelectorAll('span')
                : <Element>[if (heading != null) heading])
            .map((e) => e.text.trim())
            .toList();
    final title = details.isNotEmpty
        ? details.first.split(RegExp(r'\s*-\s*'))
        : <String>[];
    final nums = _attendanceCounts(doc);
    final present = nums.isNotEmpty ? nums[0] : '0';
    final absent = nums.length > 1 ? nums[1] : '0';
    final remaining = nums.length > 2 ? nums[2] : '0';
    final total = (int.tryParse(present) ?? 0) + (int.tryParse(absent) ?? 0);
    return {
      'code': title.isNotEmpty ? title.first.trim() : '',
      'name': title.length > 1 ? title.sublist(1).join(' - ').trim() : '',
      'teacher':
          heading?.attributes['data-teacher'] ??
          doc.querySelector('[data-teacher-name]')?.text.trim() ??
          heading?.nodes.first.text?.trim() ??
          '',
      'present': present,
      'absent': absent,
      'remaining': remaining,
      'percentage':
          '${total == 0 ? 0 : ((int.parse(present) / total) * 100).floor()}%',
      'present_dates': _parseClassDates(
        doc.querySelector(
          'table.cn-attend-list1, table[data-attendance="present"]',
        ),
      ),
      'absent_dates': _parseClassDates(
        doc.querySelector(
          'table.cn-attend-list2, table[data-attendance="absent"]',
        ),
      ),
    };
  }

  List<Map<String, String>> _parseClassDates(Element? table) =>
      table?.querySelectorAll('tbody tr').map((row) {
        final cells = row
            .querySelectorAll('td')
            .map((e) => e.text.trim())
            .toList();
        return {
          'date': cells.length > 1 ? cells[1] : '',
          'time': cells.length > 2 ? cells[2].replaceAll('TO', '-').trim() : '',
          'index': '0',
          'status': 'None',
        };
      }).toList() ??
      [];

  Map<String, dynamic> _parseMarks(Document doc) {
    final values = _marksCells(
      doc,
    ).map((e) => e.text.trim().isEmpty ? '-' : e.text.trim()).toList();
    final name =
        doc
            .querySelector(
              'th[colspan="9"], [data-course-title], .course-title',
            )
            ?.text
            .trim() ??
        '';
    final averageValues = RegExp(r'"col1"\s*:\s*(\d+)')
        .allMatches(doc.querySelector('.cn-cie-stat script')?.text ?? '')
        .map((m) => m.group(1)!)
        .toList();
    const averageKeys = ['t1', 't2', 't3', 't4', 'a1', 'a2', 'a3'];
    final averages = <String, String>{for (final key in averageKeys) key: '-'};
    for (var i = 0; i < averageValues.length && i < averageKeys.length; i++) {
      averages[averageKeys[i]] = averageValues[i];
    }
    String value(int i) => i < values.length ? values[i] : '-';
    return {
      'name': name,
      't1': value(0),
      't2': value(1),
      't3': value(2),
      't4': value(3),
      'a1': value(4),
      'a2': value(5),
      'a3': value(6),
      'final cie': value(7),
      'class_average': averages,
    };
  }

  List<Element> _marksCells(Document doc) {
    final legacy = doc.querySelectorAll('tr.odd td');
    if (legacy.isNotEmpty) return legacy;
    return doc.querySelectorAll(
      'tr[data-marks] td, table[data-section="cie"] tbody tr td',
    );
  }

  List<Map<String, dynamic>> _parsePreviousResults(Document doc) => doc
      .querySelectorAll(
        'table.res-table, table[data-section="semester-result"]',
      )
      .map((table) {
        final result = <String, dynamic>{
          'term':
              table
                  .querySelector('caption')
                  ?.nodes
                  .whereType<Text>()
                  .map((n) => n.data.trim())
                  .where((s) => s.isNotEmpty)
                  .join(' ') ??
              '',
        };
        for (final span in table.querySelectorAll('caption span')) {
          final parts = span.text.split(':');
          if (parts.length >= 2) {
            result['${parts.first.trim()}${span.text.contains('Credits') ? ' ' : ''}'] =
                parts.sublist(1).join(':').trim();
          }
        }
        result['results'] = table.querySelectorAll('tbody tr').map((row) {
          final heads = table
              .querySelectorAll('thead th')
              .map((e) => e.text.replaceAll(RegExp(r'\s+'), ' ').trim())
              .toList();
          final vals = row
              .querySelectorAll('td')
              .map((e) => e.text.trim())
              .toList();
          return <String, String>{
            for (var i = 0; i < vals.length && i < heads.length; i++)
              heads[i]: vals[i],
          };
        }).toList();
        return result;
      })
      .toList();

  List<Map<String, String>> _parseTimetable(Document doc) {
    final entries = <Map<String, String>>[];
    for (final table in doc.querySelectorAll('table')) {
      final header = _clean(table.text);
      final dateMatch = RegExp(
        r'(MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY|SATURDAY|SUNDAY)\s+(\d{2}-\d{2}-\d{4})',
        caseSensitive: false,
      ).firstMatch(header);
      final rows = table.querySelectorAll('tr');
      final columns = rows.isEmpty
          ? <String>[]
          : rows.first
                .querySelectorAll('th, td')
                .map((cell) => _label(cell.text))
                .toList();
      if (dateMatch == null ||
          !columns.any((column) => column == 'time') ||
          !columns.any((column) => column.contains('course code'))) {
        continue;
      }
      final day = dateMatch.group(1)!.toUpperCase();
      final date = _portalDateToIso(dateMatch.group(2)!);
      for (final row in table.querySelectorAll('tr').skip(1)) {
        final cells = row
            .querySelectorAll('td')
            .map((cell) => _clean(cell.text))
            .toList();
        if (cells.length < 2 || !RegExp(r'\d{1,2}:\d{2}').hasMatch(cells[0])) {
          continue;
        }
        final courseParts = cells[1].split(RegExp(r'\s+-\s+'));
        entries.add({
          'date': date,
          'day': day,
          'time': cells[0],
          'code': courseParts.first,
          'name': courseParts.length > 1
              ? courseParts.sublist(1).join(' - ')
              : cells[1],
          'faculty': cells.length > 2 ? cells[2] : '',
          'room': cells.length > 3 ? cells[3] : '',
          'batch': cells.length > 4 ? cells[4] : '',
        });
      }
    }
    return entries;
  }

  List<Map<String, String>> _parseSeating(Document doc) {
    // Sibling cards often have no literal whitespace between closing/opening
    // tags. Joining leaf nodes preserves the visual separation users see.
    final text = _clean(
      doc.body
              ?.querySelectorAll('*')
              .where((element) => element.children.isEmpty)
              .map((element) => element.text)
              .join(' ') ??
          '',
    );
    final dateMatch = RegExp(
      r'(?:MON|TUE|WED|THU|FRI|SAT|SUN)\s+(\d{1,2})\s+([A-Z]{3})\s+(\d{4})',
      caseSensitive: false,
    ).firstMatch(text);
    if (dateMatch == null) return const [];
    final details = _clean(text.substring(dateMatch.end));
    final upperDetails = details.toUpperCase();
    final timingIndex = upperDetails.indexOf(' TIMING ');
    final blockIndex = upperDetails.indexOf(' BLOCK ', timingIndex + 1);
    final roomIndex = upperDetails.indexOf(' ROOM ', blockIndex + 1);
    if (timingIndex <= 0 ||
        blockIndex <= timingIndex ||
        roomIndex <= blockIndex) {
      return const [];
    }
    final courseDetails = details.substring(0, timingIndex).trim();
    final courseSeparator = courseDetails.indexOf(' ');
    if (courseSeparator <= 0) return const [];
    final courseCode = courseDetails.substring(0, courseSeparator);
    final courseName = courseDetails.substring(courseSeparator + 1).trim();
    final timingText = details
        .substring(timingIndex + ' TIMING '.length, blockIndex)
        .trim();
    final block = details
        .substring(blockIndex + ' BLOCK '.length, roomIndex)
        .trim();
    final room = details
        .substring(roomIndex + ' ROOM '.length)
        .replaceFirst(
          RegExp(
            r'\s+(?:Contineo|Terms of Service|Privacy Policy)\b.*$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(RegExp(r'\s+Copyright.*$', caseSensitive: false), '')
        .trim();
    final sessionMatch = RegExp(r'\(([^)]+)\)').firstMatch(timingText);
    return [
      {
        'date': _namedDateToIso(
          dateMatch.group(1)!,
          dateMatch.group(2)!,
          dateMatch.group(3)!,
        ),
        'course_code': courseCode.toUpperCase(),
        'course_name': courseName,
        'timing': _clean(timingText.replaceAll(RegExp(r'\s*\([^)]+\)'), '')),
        'session':
            sessionMatch?.group(1)?.replaceAll('Sesssion', 'Session') ?? '',
        'block': block,
        'room': room,
      },
    ];
  }

  String _portalDateToIso(String value) {
    final parts = value.split('-');
    return parts.length == 3 ? '${parts[2]}-${parts[1]}-${parts[0]}' : value;
  }

  String _namedDateToIso(String day, String month, String year) {
    const months = {
      'JAN': 1,
      'FEB': 2,
      'MAR': 3,
      'APR': 4,
      'MAY': 5,
      'JUN': 6,
      'JUL': 7,
      'AUG': 8,
      'SEP': 9,
      'OCT': 10,
      'NOV': 11,
      'DEC': 12,
    };
    final monthNumber = months[month.toUpperCase()];
    if (monthNumber == null) return '';
    return '$year-${monthNumber.toString().padLeft(2, '0')}-${day.padLeft(2, '0')}';
  }

  Map<String, dynamic> _emptyProctor() => {
    'proctor_name': 'No data',
    'branch': 'No data',
    'email': 'No data',
    'phone': 'No data',
    'proctorial_notes': <dynamic>[],
  };

  Map<String, dynamic> _parseProctor(Document doc) {
    // Live header shape: bare name text node, then department, email and
    // phone each in their own span. Classify spans by pattern so missing
    // parts degrade to 'No data' instead of shifting positions.
    var name = 'No data';
    var branch = 'No data';
    var email = 'No data';
    var phone = 'No data';
    final header = doc.querySelector('h3.md-card-head-text');
    if (header != null) {
      final directText = header.nodes
          .where((node) => node is! Element)
          .map((node) => node.text?.trim() ?? '')
          .where((text) => text.isNotEmpty)
          .join(' ');
      final spans = header
          .querySelectorAll('span')
          .map((e) => e.text.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((text) => text.isNotEmpty)
          .toList();
      if (directText.isNotEmpty) {
        name = directText;
      } else if (spans.isNotEmpty) {
        name = spans.removeAt(0);
      } else {
        name = header.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (name.isEmpty) name = 'No data';
      }
      for (final span in spans) {
        if (email == 'No data' && span.contains('@')) {
          email = span;
        } else if (phone == 'No data' &&
            RegExp(r'^[\d\s+\-().]{7,}$').hasMatch(span)) {
          phone = span;
        } else if (branch == 'No data') {
          branch = span;
        }
      }
    }
    return {
      'proctor_name': name,
      'branch': branch,
      'email': email,
      'phone': phone,
      'proctorial_notes': doc
          .querySelectorAll('table.cn-res-table tbody tr')
          .map((row) {
            final cells = row
                .querySelectorAll('td')
                .map((e) => e.text.trim())
                .toList();
            return {
              'date': cells.isNotEmpty ? cells[0] : '',
              'sender': cells.length > 1 ? cells[1] : '',
              'desc': cells.length > 2 ? cells[2] : '',
            };
          })
          .toList(),
    };
  }
}
