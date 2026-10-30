import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Classes/marks.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/cie_sub_screen/widgets/cie_graph.dart';

Marks _mark(String score) => Marks(
  subjectName: 'Course (TEST)',
  a1: '-',
  a2: '-',
  finalCie: score,
  t1: '-',
  t2: '-',
  avga1: '-',
  avga2: '-',
  avgt1: '-',
  avgt2: '-',
);

void main() {
  test('unpublished and non-finite scores do not produce an empty chart', () {
    for (final raw in ['', '-', 'NaN', 'Infinity', 'Not published']) {
      expect(CieGraph.hasPlottableMarks([_mark(raw)]), isFalse);
    }
  });
  test('zero and formatted scores still produce a chart', () {
    for (final raw in ['0', '0/50', '44/50', '78%']) {
      expect(CieGraph.hasPlottableMarks([_mark('-'), _mark(raw)]), isTrue);
    }
  });
}
