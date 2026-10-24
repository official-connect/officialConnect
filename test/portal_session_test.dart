import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as parser;
import 'package:official_connect/Services/portal_session.dart';

void main() {
  test('portal navigation waits for route-specific content', () {
    Uri route(String task) => Uri.parse(
      'https://parents.msrit.edu/newparents/index.php'
      '?option=com_studentdashboard&controller=studentdashboard&task=$task',
    );

    expect(
      portalExpectedContentSelector(route('timetable')),
      'table.cn-time-table, table.cn-time_table',
    );
    expect(
      portalExpectedContentSelector(route('attendencelist')),
      contains('.cn-attend-list1'),
    );
    expect(
      portalExpectedContentSelector(route('ciedetails')),
      contains('.cn-cie-stat'),
    );
    expect(
      portalExpectedContentSelector(route('observation')),
      contains('table.cn-res-table'),
    );
  });

  test('history and fee pages retain their dedicated selectors', () {
    final resultsUri = Uri.parse(
      'https://parents.msrit.edu/newparents/index.php'
      '?option=com_history&task=getResult',
    );
    final seatingUri = Uri.parse(
      'https://parents.msrit.edu/newparents/index.php'
      '?option=com_history&task=seating',
    );
    expect(
      portalExpectedContentSelector(resultsUri),
      'table.res-table, table[data-section="semester-result"]',
    );
    expect(
      portalExpectedContentSelector(seatingUri),
      'h3, [data-section="seating"]',
    );
    final resultsPage = parser.parse(
      File('test/fixtures/results_variant.html').readAsStringSync(),
    );
    final seatingPage = parser.parse(
      File('test/fixtures/seating_variant.html').readAsStringSync(),
    );
    expect(
      resultsPage.querySelector(portalExpectedContentSelector(resultsUri)!),
      isNotNull,
    );
    expect(
      seatingPage.querySelector(portalExpectedContentSelector(seatingUri)!),
      isNotNull,
    );
    expect(
      portalExpectedContentSelector(
        Uri.parse(
          'https://parents.msrit.edu/newparents/index.php'
          '?option=com_fee&task=studFee',
        ),
      ),
      'table.cn-pay-table',
    );
  });

  test('attendance navigation matches the requested course link', () {
    final firstCourse = Uri.parse(
      'https://parents.msrit.edu/newparents/index.php'
      '?option=com_studentdashboard&controller=studentdashboard'
      '&task=attendencelist&id=course-a&ksign=session-a',
    );
    final secondCourse = Uri.parse(
      'https://parents.msrit.edu/newparents/index.php'
      '?option=com_studentdashboard&controller=studentdashboard'
      '&task=attendencelist&id=course-b&ksign=session-a',
    );

    expect(portalLinkMatchesTarget(secondCourse, firstCourse), isFalse);
    expect(portalLinkMatchesTarget(secondCourse, secondCourse), isTrue);
    expect(
      portalLinkMatchesTarget(
        Uri.parse(
          'https://parents.msrit.edu/newparents/index.php'
          '?task=attendencelist&id=course-b',
        ),
        secondCourse,
      ),
      isTrue,
    );
  });

  test('content waits are uniform and task-based, never option-based', () {
    final resultsUri = Uri.parse(
      'https://parents.msrit.edu/newparents/index.php'
      '?option=com_history&task=getResult',
    );
    final seatingUri = Uri.parse(
      'https://parents.msrit.edu/newparents/index.php'
      '?option=com_history&task=seating',
    );
    final attendanceUri = Uri.parse(
      'https://parents.msrit.edu/newparents/index.php'
      '?option=com_studentdashboard&controller=studentdashboard'
      '&task=attendencelist&id=course-a',
    );
    // Regression: seating links carry option=com_history and must not
    // inherit the long results wait through the option fallback.
    expect(portalContentWaitAttempts(resultsUri), 24);
    expect(portalContentWaitAttempts(seatingUri), 24);
    expect(portalContentWaitAttempts(attendanceUri), 24);
  });

  test('portal failures expose only bounded diagnostic reasons', () {
    final signedUri = Uri.parse(
      'https://parents.msrit.edu/newparents/index.php?ksign=secret-token',
    );

    expect(
      portalFailureReason(PortalContentNotReadyException(signedUri)),
      'content_not_ready',
    );
    expect(
      portalFailureReason(
        PortalRequestException(signedUri, 'request timed out'),
      ),
      'timeout',
    );
    expect(
      portalFailureReason(const SocketException('network unavailable')),
      'network_error',
    );
    expect(
      PortalRequestException(signedUri, 'request failed').toString(),
      isNot(contains('secret-token')),
    );
  });
}
