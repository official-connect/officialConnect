import 'package:flutter/material.dart';
import 'package:official_connect/Classes/marks.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:provider/provider.dart';
import 'package:official_connect/Providers/sisdata.dart';

class CieGraph extends StatefulWidget {
  const CieGraph({Key? key, required this.marks}) : super(key: key);
  final List<Marks> marks;

  static bool hasPlottableMarks(List<Marks> marks) =>
      marks.any((mark) => _CieGraphState._parseCieValue(mark.finalCie) != null);

  @override
  State<CieGraph> createState() => _CieGraphState();
}

class _CieGraphState extends State<CieGraph> {
  late TooltipBehavior _tooltipBehavior;

  /// Extracts a plottable number from formats like "44/50", "78%", "-".
  /// Returns null when there is nothing numeric to plot.
  static double? _parseCieValue(String raw) {
    var s = raw.trim();
    if (s.isEmpty || s == '-') return null;
    s = s.replaceAll('%', '').split('/').first.trim();
    final value = double.tryParse(s);
    return value != null && value.isFinite ? value : null;
  }

  @override
  void initState() {
    // documentation at https://help.syncfusion.com/flutter/cartesian-charts/tooltip for customisation.
    _tooltipBehavior = TooltipBehavior(
      enable: true,
      header: "Subject Code",
      tooltipPosition: TooltipPosition.pointer,
    );
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final sisData = Provider.of<SisData>(context);

    return SfCartesianChart(
      onTooltipRender: (TooltipArgs args) {
        final i = args.pointIndex?.toInt();
        if (i != null && i >= 0 && i < widget.marks.length) {
          args.header = widget.marks[i].subjectName;
          args.text = widget.marks[i].finalCie;
        }
      },
      tooltipBehavior: _tooltipBehavior,
      primaryXAxis: CategoryAxis(
        labelIntersectAction: AxisLabelIntersectAction.rotate45,
        labelStyle: TextStyle(
          color: sisData.darkMode ? Colors.white54 : Colors.black54,
          fontSize: 10,
          fontFamily: 'Comfortaa',
        ),
      ),
      isTransposed: true,
      primaryYAxis: NumericAxis(
        minimum: 0,
        maximum: widget.marks
            .map((m) => _parseCieValue(m.finalCie) ?? 0)
            .fold<double>(50, (a, b) => b > a ? b.toDouble() : a),
      ),
      series: <CartesianSeries<Marks, String>>[
        BarSeries<Marks, String>(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(7),
            topRight: Radius.circular(7),
          ),
          gradient: const LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [Colors.blue, Colors.red],
          ),
          // Bind data source
          dataSource: widget.marks,
          xValueMapper: (Marks a, _) =>
              RegExp(r'\(([^)]*)\)').firstMatch(a.subjectName)?.group(1) ??
              a.subjectName,
          yValueMapper: (Marks b, _) => _parseCieValue(b.finalCie),
          enableTooltip: true,
        ),
      ],
    );
  }
}
