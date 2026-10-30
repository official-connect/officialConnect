// ignore_for_file: prefer_typing_uninitialized_variables

import 'dart:async';

import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:official_connect/Providers/themes.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/cie_sub_screen/cie_details/cie_details.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/cie_sub_screen/widgets/cie_graph.dart';
import 'package:official_connect/Screens/login_screen/student_home/widgets/sync_issue_notice.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';

class CIEScreen extends StatelessWidget {
  final height,
      titleStyle,
      buttonTitle,
      isSEE,
      width,
      seeOpt,
      neumorphicStyle,
      sisData,
      buttonTrailing;
  const CIEScreen({
    Key? key,
    this.height,
    this.titleStyle,
    this.buttonTitle,
    this.isSEE,
    this.width,
    this.seeOpt,
    this.neumorphicStyle,
    this.sisData,
    this.buttonTrailing,
  }) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(
              "Results",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.left,
              style: titleStyle.copyWith(fontSize: 30.0),
            ),
            // NeumorphicButton(
            //   child: Icon(
            //     FontAwesomeIcons.bookAtlas,
            //     color: sisData.darkMode ? Colors.white : Colors.black,
            //     size: width * 0.05,
            //   ),
            //   style: neumorphicStyle,
            //   onPressed: () {
            //     _launchURL(context,
            //         "https://drive.google.com/drive/folders/1xPhB1sYr3TdHmgURiogcqBfJpj7YKyEc?usp=sharing");
            //   },
            // ),
            // NeumorphicButton(
            //   child: Icon(
            //     FontAwesomeIcons.book,
            //     color: sisData.darkMode ? Colors.white : Colors.black,
            //     size: width * 0.05,
            //   ),
            //   style: neumorphicStyle,
            //   onPressed: () {
            //     Navigator.of(context).push(MaterialPageRoute(
            //         builder: (ctx) => const SyllabusScreen()));
            //
            //     // DummyData.syllabusLinks.keys.forEach((element) {
            //     //   if (RegExp(r"[\w\s]*" + fullCourseName + r"$")
            //     //       .hasMatch(element)) {
            //     //     Navigator.of(context).push(MaterialPageRoute(
            //     //         builder: (ctx) => BranchSyllabus(name: element)));
            //     //   }
            //     // });
            //   },
            // ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () {
                      unawaited(SyncDiagnostics.recordFeature('cie_marks'));
                      seeOpt.value = false;
                    },
                    child: Text(
                      "CIE",
                      textAlign: TextAlign.left,
                      style: CustomTheme.titleStyle(context).copyWith(
                        color: const Color(0xffba3237),
                        fontSize: seeOpt.value ? 19.0 : 23.0,
                        fontWeight: (seeOpt.value
                            ? FontWeight.normal
                            : FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: VerticalDivider(
                    color: sisData.darkMode ? Colors.white38 : Colors.black26,
                    thickness: 1.6,
                    width: 10,
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      unawaited(
                        SyncDiagnostics.recordFeature('semester_results'),
                      );
                      seeOpt.value = true;
                    },
                    child: Text(
                      "SEE",
                      textAlign: TextAlign.right,
                      style: CustomTheme.titleStyle(context).copyWith(
                        color: Colors.grey,
                        fontSize: !seeOpt.value ? 19.0 : 23.0,
                        fontWeight: (!seeOpt.value
                            ? FontWeight.normal
                            : FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SyncIssueNotice(
          sisData: sisData,
          section: 'marks',
          hasVisibleData: sisData.marks.isNotEmpty,
        ),
        sisData.marks.isEmpty
            ? Padding(
                padding: EdgeInsets.only(top: height * 0.035),
                child: Neumorphic(
                  style: neumorphicStyle,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 28,
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.fact_check_outlined,
                        color: Color(0xffba3237),
                        size: 44,
                      ),
                      const SizedBox(height: 14),
                      Text('No current CIE data', style: buttonTrailing),
                      const SizedBox(height: 8),
                      Text(
                        'Switch to SEE for your semester results, or refresh to check for new internal marks.',
                        textAlign: TextAlign.center,
                        style: buttonTitle.copyWith(
                          color: sisData.darkMode
                              ? Colors.white60
                              : Colors.black54,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : !CieGraph.hasPlottableMarks(sisData.marks)
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'Marks haven’t been published yet',
                  textAlign: TextAlign.center,
                  style: buttonTitle,
                ),
              )
            : SizedBox(
                height: (220.0 + sisData.marks.length * 8).clamp(240.0, 300.0),
                child: CieGraph(marks: sisData.marks),
              ),
        ...sisData.marks
            .map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: NeumorphicButton(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (ctx) => CIEDetails(subjectDetails: e),
                      ),
                    );
                  },
                  style: neumorphicStyle,
                  child: ListTile(
                    minVerticalPadding: 8,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: Text(
                      e.subjectName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: buttonTitle.copyWith(fontSize: 16.0, height: 1.3),
                    ),
                    trailing: Text(
                      e.finalCie.contains('%')
                          ? "-"
                          : ((e.t1 == '-') ? e.t1 : e.finalCie.toString()),
                      style: buttonTrailing.copyWith(fontSize: 18.0),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
        const SizedBox(height: 32),
      ],
    );
  }
}
