import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:official_connect/Providers/themes.dart';
import 'package:official_connect/Screens/login_screen/portal_refresh.dart';
import 'package:official_connect/Screens/login_screen/student_home/unified_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/settings_screen/widgets/about_dialog.dart';
import 'package:provider/provider.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:official_connect/Services/app_support.dart';
import 'package:official_connect/Services/safe_external_link.dart';

class SettingsInfo extends StatelessWidget {
  const SettingsInfo({Key? key, this.linkLauncher}) : super(key: key);
  final ExternalLinkLauncher? linkLauncher;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final width = size.width;
    final height = size.height;
    final sisData = Provider.of<SisData>(context);
    final buttonTitle = CustomTheme.buttonTitle(context);
    final buttonTrailing = CustomTheme.buttonTrailing(context);
    final title = CustomTheme.titleStyle(context);
    final neumorphicStyle = CustomTheme.neumorphicStyle(context);
    final linearGradientBG = CustomTheme.linearGradientBG(context);
    // var fullCourseName = sisData.courseFullName.split("-")[1];
    List<Element> tiles = [
      Element(
        icon: Icons.info_outline_rounded,
        onPressed: () {
          unawaited(SyncDiagnostics.recordFeature('about'));
          showDialog(
            builder: (context) => AboutConnectDialog(
              sisData: sisData,
              width: width,
              title: title,
              height: height,
            ),
            context: context,
          );
        },
        text: "About",
      ),
      Element(
        icon: Icons.update,
        onPressed: () {
          unawaited(SyncDiagnostics.recordFeature('update_data'));
          openPortalRefresh(context);
        },
        text: "Update data",
      ),
    ];

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
              bottom: height * 0.06,
            ),
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.only(bottom: height * 0.025),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      "Settings",
                      textAlign: TextAlign.left,
                      style: title,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Neumorphic(
                    style: neumorphicStyle,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.palette_outlined,
                                color: Color(0xffd93b3f),
                                size: 28,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Appearance', style: buttonTitle),
                                    Text(
                                      'Choose how OfficialConnect looks',
                                      style: CustomTheme.textStyle(context)
                                          .copyWith(
                                            fontSize: 12.5,
                                            color: sisData.darkMode
                                                ? Colors.white60
                                                : Colors.black54,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<String>(
                              key: const ValueKey('theme-selector'),
                              showSelectedIcon: false,
                              style: ButtonStyle(
                                foregroundColor:
                                    WidgetStateProperty.resolveWith((states) {
                                      if (states.contains(
                                        WidgetState.selected,
                                      )) {
                                        return const Color(0xff4b4552);
                                      }
                                      return sisData.darkMode
                                          ? Colors.white70
                                          : Colors.black87;
                                    }),
                                backgroundColor:
                                    WidgetStateProperty.resolveWith((states) {
                                      return states.contains(
                                            WidgetState.selected,
                                          )
                                          ? const Color(0xffe6daf7)
                                          : Colors.transparent;
                                    }),
                                side: WidgetStatePropertyAll(
                                  BorderSide(
                                    color: sisData.darkMode
                                        ? Colors.white38
                                        : Colors.black45,
                                  ),
                                ),
                              ),
                              segments: const [
                                ButtonSegment(
                                  value: 'system',
                                  icon: Icon(Icons.phone_android, size: 17),
                                  label: Text('System'),
                                ),
                                ButtonSegment(
                                  value: 'light',
                                  icon: Icon(Icons.light_mode, size: 17),
                                  label: Text('Light'),
                                ),
                                ButtonSegment(
                                  value: 'dark',
                                  icon: Icon(Icons.dark_mode, size: 17),
                                  label: Text('Dark'),
                                ),
                              ],
                              selected: {sisData.themeMode},
                              onSelectionChanged: (selection) {
                                sisData.themeMode = selection.first;
                                unawaited(
                                  SyncDiagnostics.recordPreference(
                                    'theme',
                                    selection.first,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                ...tiles.map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: NeumorphicButton(
                      onPressed: e.onPressed,
                      style: neumorphicStyle,
                      child: ListTile(
                        leading: Icon(
                          e.icon,
                          color: const Color(0xffd93b3f),
                          size: 30,
                        ),
                        title: Text(e.text, style: buttonTitle),
                        trailing: const Icon(Icons.chevron_right, size: 20),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Neumorphic(
                    style: neumorphicStyle,
                    child: SwitchListTile.adaptive(
                      secondary: const Icon(
                        Icons.insights_outlined,
                        color: Color(0xffd93b3f),
                        size: 30,
                      ),
                      title: Text('Help improve the app', style: buttonTitle),
                      subtitle: Text(
                        'Share anonymous feature usage and update health. Student details and marks are not included.',
                        style: CustomTheme.textStyle(context).copyWith(
                          fontSize: 12.5,
                          color: sisData.darkMode
                              ? Colors.white54
                              : Colors.black54,
                        ),
                      ),
                      value: sisData.diagnosticsEnabled,
                      activeThumbColor: const Color(0xffba3237),
                      onChanged: (value) {
                        sisData.diagnosticsEnabled = value;
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Help & feedback', style: buttonTrailing),
                ),
                const SizedBox(height: 8),
                for (final (action, label, subtitle, icon) in [
                  (
                    'app_feedback',
                    'Share feedback',
                    'Tell us what could work better',
                    Icons.feedback_outlined,
                  ),
                  (
                    'report_bug',
                    'Report a bug',
                    'Open a bug report on GitHub',
                    Icons.bug_report_outlined,
                  ),
                  if (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.android)
                    (
                      'rate_app',
                      'Rate the app',
                      'Open our Play Store listing',
                      Icons.star_outline_rounded,
                    ),
                  (
                    'source_code',
                    'Source code',
                    'Explore the project and contribute',
                    Icons.code_rounded,
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: NeumorphicButton(
                      key: ValueKey('support-$action'),
                      style: neumorphicStyle,
                      onPressed: () => unawaited(
                        AppSupport.open(
                          context,
                          action: action,
                          source: 'settings',
                          launcher: linkLauncher,
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        leading: Icon(
                          icon,
                          color: const Color(0xffd93b3f),
                          size: 28,
                        ),
                        title: Text(label, style: buttonTitle),
                        subtitle: Text(
                          subtitle,
                          style: CustomTheme.buttonSubtitle(context),
                        ),
                        trailing: Icon(
                          Icons.open_in_new,
                          size: 18,
                          color: sisData.darkMode
                              ? Colors.white70
                              : Colors.black54,
                        ),
                      ),
                    ),
                  ),
                SizedBox(height: height * 0.035),
                Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (ctx) {
                              return AlertDialog(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                backgroundColor: sisData.darkMode
                                    ? Colors.black
                                    : NeumorphicColors.background,
                                title: Text('Sign out?', style: buttonTrailing),
                                content: Text(
                                  'Cached portal data will be removed. Your saved login suggestions will remain for next time.',
                                  style: buttonTitle,
                                ),
                                actions: <Widget>[
                                  NeumorphicButton(
                                    style: neumorphicStyle,
                                    onPressed: () {
                                      Navigator.of(context).pop(false);
                                    },
                                    child: Text('Cancel', style: buttonTitle),
                                  ),
                                  NeumorphicButton(
                                    style: neumorphicStyle,
                                    onPressed: () {
                                      Unified.screenNumber.value = 2;
                                      Navigator.of(context).pop(false);
                                      sisData.cleanData();
                                    },
                                    child: const Text(
                                      'Sign out',
                                      style: TextStyle(
                                        color: Color(0xffba3237),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                        icon: const Icon(Icons.logout, size: 18),
                        label: const Text('Sign out'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xffba3237),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: height * 0.015),
                SizedBox(height: height * 0.07),
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
  final IconData icon;
  Element({required this.onPressed, required this.text, required this.icon});
}
