import 'dart:async';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:official_connect/Providers/dummy_data.dart';
import 'package:official_connect/Screens/login_screen/student_home/events_screen/widgets/about_club_dialog.dart';
import 'package:provider/provider.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:official_connect/Providers/themes.dart';
import 'package:official_connect/Screens/login_screen/portal_refresh.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/syllabus_sub_screen/syllabus_screen.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:official_connect/Services/safe_external_link.dart';
import 'package:official_connect/Services/app_support.dart';
import 'package:official_connect/Screens/login_screen/student_home/timetable_screen/timetable_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/seating_screen/seating_screen.dart';

typedef ExploreLinkLauncher = Future<bool> Function(Uri uri);

class ExploreLink {
  const ExploreLink({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.url,
    required this.icon,
    required this.analyticsFeature,
  });

  final String key;
  final String title;
  final String subtitle;
  final String url;
  final IconData icon;
  final String analyticsFeature;
}

const campusServiceLinks = <ExploreLink>[
  ExploreLink(
    key: 'fee-payment',
    title: 'Fee payment',
    subtitle: 'Official payment links and current notices',
    url: 'https://www.msrit.edu/',
    icon: Icons.payments_outlined,
    analyticsFeature: 'fee_payment',
  ),
  ExploreLink(
    key: 'wifi-helpdesk',
    title: 'Campus helpdesk',
    subtitle: 'Report Wi-Fi and other campus IT issues',
    url: 'https://rithelpdesk.msrit.edu/',
    icon: Icons.support_agent_outlined,
    analyticsFeature: 'campus_helpdesk',
  ),
  ExploreLink(
    key: 'app-feedback',
    title: 'Share app feedback',
    subtitle: 'Tell us what could work better',
    url: AppSupport.feedbackUrl,
    icon: Icons.feedback_outlined,
    analyticsFeature: 'app_feedback',
  ),
];

class _AcademicQuickLinks extends StatelessWidget {
  const _AcademicQuickLinks({required this.style, required this.titleStyle});

  final NeumorphicStyle style;
  final TextStyle titleStyle;

  @override
  Widget build(BuildContext context) {
    final sisData = context.watch<SisData>();
    final subtitle = CustomTheme.textStyle(context).copyWith(
      fontSize: 13,
      color: sisData.darkMode ? Colors.white60 : Colors.black54,
    );
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Academic tools', style: CustomTheme.titleStyle(context)),
        ),
        const SizedBox(height: 8),
        _QuickLink(
          key: const ValueKey('timetable'),
          style: style,
          icon: Icons.calendar_view_week_outlined,
          title: 'Timetable',
          subtitle: 'See your weekly schedule at a glance',
          titleStyle: titleStyle,
          subtitleStyle: subtitle,
          onPressed: () {
            unawaited(SyncDiagnostics.recordFeature('timetable'));
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const TimetableScreen()));
          },
        ),
        _QuickLink(
          key: const ValueKey('exam-seating'),
          style: style,
          icon: Icons.event_seat_outlined,
          title: 'Exam seating',
          subtitle: 'Find your room before the exam',
          titleStyle: titleStyle,
          subtitleStyle: subtitle,
          onPressed: () {
            unawaited(SyncDiagnostics.recordFeature('exam_seating'));
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SeatingScreen()));
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _QuickLink extends StatelessWidget {
  const _QuickLink({
    super.key,
    required this.style,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.titleStyle,
    required this.subtitleStyle,
    required this.onPressed,
  });

  final NeumorphicStyle style;
  final IconData icon;
  final String title;
  final String subtitle;
  final TextStyle titleStyle;
  final TextStyle subtitleStyle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: NeumorphicButton(
      style: style,
      onPressed: onPressed,
      child: ListTile(
        leading: Icon(icon, color: const Color(0xffd93b3f), size: 28),
        title: Text(title, style: titleStyle),
        subtitle: Text(subtitle, style: subtitleStyle),
        trailing: const Icon(Icons.chevron_right, size: 20),
      ),
    ),
  );
}

class EventsScreen extends StatelessWidget {
  const EventsScreen({Key? key, this.linkLauncher}) : super(key: key);

  final ExploreLinkLauncher? linkLauncher;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final width = size.width;
    final height = size.height;
    final sisData = Provider.of<SisData>(context);
    final buttonTitle = CustomTheme.buttonTitle(context);
    final title = CustomTheme.titleStyle(context);
    final neumorphicStyle = CustomTheme.neumorphicStyle(context);
    final linearGradientBG = CustomTheme.linearGradientBG(context);
    Future<void> openLink(String url, String feature) async {
      if (feature == 'app_feedback') {
        await AppSupport.open(
          context,
          action: feature,
          source: 'explore',
          launcher: linkLauncher,
        );
        return;
      }
      final uri = Uri.parse(url);
      final launched = await openExternalLink(
        context,
        uri,
        launcher: linkLauncher,
      );
      if (launched) {
        unawaited(SyncDiagnostics.recordFeature(feature));
      }
    }

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
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          child: Container(
            decoration: BoxDecoration(gradient: linearGradientBG),
            padding: EdgeInsets.only(
              left: width * 0.05,
              right: width * 0.05,
              top: height * 0.06,
              bottom: height * 0.13,
            ),
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.only(bottom: height * 0.015),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text('Explore', style: title),
                  ),
                ),
                _AcademicQuickLinks(
                  style: neumorphicStyle,
                  titleStyle: buttonTitle,
                ),
                Padding(
                  padding: EdgeInsets.only(bottom: height * 0.015),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text('Campus services', style: title),
                  ),
                ),
                ...campusServiceLinks.map(
                  (link) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: NeumorphicButton(
                      key: ValueKey(link.key),
                      style: neumorphicStyle,
                      onPressed: () =>
                          openLink(link.url, link.analyticsFeature),
                      child: ListTile(
                        leading: Icon(
                          link.icon,
                          color: const Color(0xffd93b3f),
                          size: 28,
                        ),
                        title: Text(link.title, style: buttonTitle),
                        subtitle: Text(
                          link.subtitle,
                          style: CustomTheme.textStyle(context).copyWith(
                            fontSize: 13,
                            color: sisData.darkMode
                                ? Colors.white60
                                : Colors.black54,
                          ),
                        ),
                        trailing: const Icon(Icons.open_in_new, size: 18),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: height * 0.02),
                  child: Divider(
                    color: sisData.darkMode ? Colors.white38 : Colors.black26,
                    thickness: 1.6,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(bottom: height * 0.025),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      "Clubs and communities",
                      textAlign: TextAlign.left,
                      style: title,
                    ),
                  ),
                ),
                ...DummyData.clubs.map(
                  (e) => Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: NeumorphicButton(
                      style: neumorphicStyle,
                      onPressed: () {
                        unawaited(
                          SyncDiagnostics.recordFeature('club_details'),
                        );
                        showDialog(
                          builder: (context) => AboutClubDialog(
                            e: e,
                            sisData: sisData,
                            width: width,
                            title: title,
                            height: height,
                          ),
                          context: context,
                        );
                      },
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 2,
                        ),
                        leading: SizedBox(
                          width: 48,
                          height: 42,
                          child: Image.asset(
                            'images/club_images/' +
                                (sisData.darkMode ? "dark_" : "light_") +
                                e['image']!,
                            fit: BoxFit.contain,
                          ),
                        ),
                        title: Text(e['name']!, style: buttonTitle),
                        trailing: const Icon(Icons.chevron_right, size: 20),
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: EdgeInsets.only(
                    left: width * 0.1,
                    right: width * 0.1,
                    top: height * 0.03,
                  ),
                  child: Divider(
                    color: sisData.darkMode ? Colors.white38 : Colors.black26,
                    thickness: 1.6,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: height * 0.025),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text("More academic resources", style: title),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: NeumorphicButton(
                    child: ListTile(
                      leading: FaIcon(
                        FontAwesomeIcons.bookAtlas,
                        color: sisData.darkMode ? Colors.white : Colors.black,
                      ),
                      title: Text("Course Material", style: buttonTitle),
                    ),
                    style: neumorphicStyle,
                    onPressed: () {
                      openLink(
                        "https://drive.google.com/drive/folders/1xPhB1sYr3TdHmgURiogcqBfJpj7YKyEc?usp=sharing",
                        'course_material',
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: NeumorphicButton(
                    child: ListTile(
                      leading: FaIcon(
                        FontAwesomeIcons.book,
                        color: sisData.darkMode ? Colors.white : Colors.black,
                      ),
                      title: Text("Syllabi", style: buttonTitle),
                    ),
                    style: neumorphicStyle,
                    onPressed: () {
                      unawaited(SyncDiagnostics.recordFeature('syllabi'));
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (ctx) => const SyllabusScreen(),
                        ),
                      );

                      // DummyData.syllabusLinks.keys.forEach((element) {
                      //   if (RegExp(r"[\w\s]*" + fullCourseName + r"$")
                      //       .hasMatch(element)) {
                      //     Navigator.of(context).push(MaterialPageRoute(
                      //         builder: (ctx) => BranchSyllabus(name: element)));
                      //   }
                      // });
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Element {
  final Function() onPressed;
  final String text;
  final String img;
  Element({required this.onPressed, required this.text, required this.img});
}
