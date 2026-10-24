import 'package:auto_size_text/auto_size_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:official_connect/Screens/login_screen/student_home/home_screen/widgets/proctor_messages_card.dart';
import 'package:official_connect/Screens/login_screen/student_home/home_screen/widgets/fees_card.dart';
import 'package:provider/provider.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Providers/themes.dart';
import 'package:flutter/foundation.dart';
import 'package:official_connect/Screens/login_screen/portal_refresh.dart';
import 'package:official_connect/Screens/login_screen/student_home/home_screen/widgets/today_timetable_card.dart';

extension StringCasingExtension on String {
  String toCapitalized() =>
      length > 0 ? '${this[0].toUpperCase()}${substring(1).toLowerCase()}' : '';
  String toTitleCase() => replaceAll(
    RegExp(' +'),
    ' ',
  ).split(' ').map((str) => str.toCapitalized()).join(' ');
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final width = size.width;
    final height = size.height;
    final buttonTitle = CustomTheme.buttonTitle(context);
    final buttonTrailing = CustomTheme.buttonTrailing(context);
    final title = CustomTheme.textStyle(context);
    final neumorphicStyle = CustomTheme.neumorphicStyle(context);
    final linearGradient = CustomTheme.linearGradient(context);
    final linearGradientBG = CustomTheme.linearGradientBG(context);
    final subtitle = CustomTheme.buttonSubtitle(context);
    final sisData = Provider.of<SisData>(context);
    bool isKnown(String value) =>
        value.trim().isNotEmpty && !value.toLowerCase().contains('unknown');
    final hasStudentImage =
        sisData.studentImage.trim().isNotEmpty &&
        !sisData.studentImage.contains('defaultimages');
    ImageProvider? studentImageProvider;
    if (hasStudentImage) {
      final source = sisData.studentImage;
      if (source.startsWith('data:')) {
        final parsed = UriData.parse(source);
        studentImageProvider = MemoryImage(parsed.contentAsBytes());
      } else if (!kIsWeb) {
        studentImageProvider = CachedNetworkImageProvider(source);
      } else {
        studentImageProvider = CachedNetworkImageProvider(
          "https://sis-scraper-rit.herokuapp.com/getimage/" +
              source.split('/').last.split('.').first,
        );
      }
    }
    final classParts = [
      sisData.semester,
      sisData.section,
    ].where(isKnown).toList();
    return Container(
      decoration: BoxDecoration(gradient: linearGradientBG),
      child: RefreshIndicator(
        displacement: height * 0.1,
        backgroundColor: sisData.darkMode
            ? const Color(0xff101114)
            : Colors.white,
        color: sisData.darkMode
            ? const Color(0xffba3237)
            : const Color(0xffba3227),
        onRefresh: () async {
          await openPortalRefresh(context);
        },
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Container(
            decoration: BoxDecoration(gradient: linearGradient),
            padding: EdgeInsets.only(
              left: width * 0.08,
              right: width * 0.08,
              top: height * 0.06,
            ),
            child: Center(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset(
                    'images/logo.png',
                    color: sisData.darkMode ? (Colors.white) : null,
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.02,
                      vertical: height * 0.02,
                    ),
                    child: Neumorphic(
                      style: neumorphicStyle,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: width * 0.05,
                          vertical: height * 0.025,
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: EdgeInsets.only(bottom: height * 0.02),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                mainAxisSize: MainAxisSize.max,
                                children: [
                                  Expanded(
                                    child: AutoSizeText(
                                      "Hi, ${sisData.studentName.toTitleCase()} 👋",
                                      maxLines: 2,
                                      style: buttonTrailing.copyWith(
                                        // fontFamily: "Lobster",
                                        fontSize: width * 0.08,
                                        fontWeight: FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  Neumorphic(
                                    style: neumorphicStyle.copyWith(
                                      boxShape:
                                          const NeumorphicBoxShape.circle(),
                                    ),
                                    child: CircleAvatar(
                                      child: studentImageProvider == null
                                          ? const Icon(
                                              Icons.person_outline,
                                              color: Color(0xffba3237),
                                              size: 34,
                                            )
                                          : null,
                                      backgroundImage: studentImageProvider,
                                      // A stale legacy URL can fail after the
                                      // browser session expires; keep the
                                      // avatar fallback without a framework
                                      // error being reported as a crash.
                                      onBackgroundImageError: (_, __) {},
                                      backgroundColor: sisData.darkMode
                                          ? Colors.white12
                                          : Colors.white70,
                                      radius: width * 0.1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (classParts.isNotEmpty)
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "Class ",
                                    style: buttonTitle.copyWith(
                                      fontSize: width * 0.045,
                                    ),
                                  ),
                                  Expanded(
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        vertical: height * 0.01,
                                        horizontal: width * 0.02,
                                      ),
                                      child: Text(
                                        classParts.join(' · '),
                                        style: subtitle,
                                        textAlign: TextAlign.end,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      // decoration: BoxDecoration(
                                      // border: Border.all(width: 1.3),
                                      // borderRadius: BorderRadius.circular(width)),
                                    ),
                                  ),
                                ],
                              ),
                            if (isKnown(sisData.course))
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "Course ",
                                    style: buttonTitle.copyWith(
                                      fontSize: width * 0.045,
                                    ),
                                  ),
                                  Expanded(
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        vertical: height * 0.01,
                                        horizontal: width * 0.02,
                                      ),
                                      child: Text(
                                        sisData.course,
                                        style: subtitle,
                                        textAlign: TextAlign.end,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      // decoration: BoxDecoration(
                                      // border: Border.all(width: 1.3),
                                      // borderRadius: BorderRadius.circular(width)),
                                    ),
                                  ),
                                ],
                              ),
                            if (classParts.isEmpty && !isKnown(sisData.course))
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xffba3237,
                                    ).withValues(alpha: 0.09),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    sisData.isSyncPending
                                        ? 'Updating other information'
                                        : sisData.hasSyncIssues
                                        ? 'Some information needs updating'
                                        : 'Information up to date',
                                    style: subtitle.copyWith(
                                      color: const Color(0xffba3237),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  TodayTimetableCard(sisData: sisData),
                  Container(
                    //line between student card and fees card
                    padding: EdgeInsets.only(
                      left: width * 0.1,
                      right: width * 0.1,
                      top: height * 0.03,
                      bottom: height * 0.015,
                    ),
                    child: Divider(
                      color: sisData.darkMode ? Colors.white38 : Colors.black26,
                      thickness: 1.6,
                    ),
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: height * 0.02),
                        child: Center(
                          child: ListTile(
                            title: AutoSizeText(
                              "Proctor Notes",
                              maxLines: 1,
                              style: buttonTrailing,
                            ),
                          ),
                        ),
                      ),
                      ...sisData.proctordata.messages
                          .map(
                            (e) => ProctorMessagesCard(
                              height: height,
                              width: width,
                              title: title,
                              subtitle: subtitle,
                              neumorphicStyle: neumorphicStyle,
                              buttonTrailing: buttonTrailing,
                              isDark: sisData.darkMode,
                              messageData: e,
                            ),
                          )
                          .toList()
                          .reversed,
                      sisData.proctordata.messages.isEmpty
                          ? Text(
                              "No messages from proctor",
                              style: subtitle.copyWith(fontSize: width * 0.04),
                            )
                          : Container(),
                    ],
                  ),
                  Container(
                    //line between ProctorMessages card and fees card
                    padding: EdgeInsets.only(
                      left: width * 0.1,
                      right: width * 0.1,
                      top: height * 0.03,
                      bottom: height * 0.015,
                    ),
                    child: Divider(
                      color: sisData.darkMode ? Colors.white38 : Colors.black26,
                      thickness: 1.6,
                    ),
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: width * 0.2,
                          vertical: height * 0.02,
                        ),
                        child: Text("Your Fees Paid", style: buttonTrailing),
                      ),
                      ...sisData.fees.map(
                        (e) => FeesCard(
                          height: height,
                          width: width,
                          neumorphicStyle: neumorphicStyle,
                          feeData: e,
                          buttonTrailing: buttonTrailing,
                          subtitle: subtitle,
                          title: title,
                          isDark: sisData.darkMode,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: height * 0.13),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
