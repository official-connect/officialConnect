import 'dart:async';

import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Providers/themes.dart';
import 'package:official_connect/Screens/login_screen/login_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/attendance_screen/attendance_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/events_screen/events_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/home_screen/home_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/results_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/settings_screen/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:official_connect/Widgets/background_sync_status.dart';
import 'package:official_connect/Screens/login_screen/portal_refresh.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';

class Unified extends StatefulWidget {
  static const String id = 'unified';
  static final ValueNotifier<int> screenNumber = ValueNotifier(2);

  const Unified({super.key});

  @override
  State<Unified> createState() => _UnifiedState();
}

class _UnifiedState extends State<Unified> with WidgetsBindingObserver {
  static const _screenNames = [
    'explore',
    'results',
    'home',
    'attendance',
    'settings',
  ];

  /// Width at or above which the persistent tablet navigation treatment
  /// (NavigationRail + width-constrained content) replaces the phone
  /// bottom navigation bar. Follows the Material breakpoint for rails.
  static const double tabletBreakpoint = 600;

  /// Maximum content width on tablet layouts so pages do not stretch
  /// across wide screens.
  static const double tabletMaxContentWidth = 900;

  static const _destinations = [
    (icon: Icons.explore_outlined, activeIcon: Icons.explore, label: 'Explore'),
    (
      icon: Icons.assessment_outlined,
      activeIcon: Icons.assessment,
      label: 'Results',
    ),
    (icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Home'),
    (
      icon: Icons.calendar_month_outlined,
      activeIcon: Icons.calendar_month,
      label: 'Attendance',
    ),
    (
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings,
      label: 'Settings',
    ),
  ];
  late final PageController _pageController;
  final ValueNotifier<bool> _showSee = ValueNotifier(false);
  bool _automaticRefreshRequested = false;
  bool _initialScreenRecorded = false;
  String? _activeScreen;
  DateTime? _screenEnteredAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(initialPage: Unified.screenNumber.value);
  }

  @override
  void dispose() {
    _flushScreenDuration();
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _showSee.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _flushScreenDuration();
    } else if (state == AppLifecycleState.resumed && _activeScreen == null) {
      _activeScreen = _screenNames[Unified.screenNumber.value];
      _screenEnteredAt = DateTime.now();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sisData = Provider.of<SisData>(context);
    if ((sisData.usn.isEmpty && !sisData.hasData) || !sisData.isValidData) {
      return const LoginScreen();
    }
    // A stale cache is still useful and must remain navigable while a refresh
    // runs. Only block when there is genuinely nothing available to render.
    if (sisData.data.isEmpty) {
      return Scaffold(
        backgroundColor: sisData.darkMode
            ? const Color(0xff101114)
            : Colors.white,
        body: const Center(
          child: SpinKitSpinningLines(color: Color(0xffba3237), size: 80),
        ),
      );
    }

    if (!_initialScreenRecorded) {
      _initialScreenRecorded = true;
      _activeScreen = _screenNames[Unified.screenNumber.value];
      _screenEnteredAt = DateTime.now();
      unawaited(SyncDiagnostics.recordScreen(_activeScreen!));
    }

    if (!_automaticRefreshRequested &&
        sisData.hasData &&
        sisData.needToUpdate &&
        FirebaseFeatureFlags.automaticRefreshEnabled) {
      _automaticRefreshRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          openPortalRefresh(context, allowInteractiveFallback: false);
        }
      });
    }

    // Continue the page's bottom surface through the refresh footer and nav.
    final navColor = CustomTheme.linearGradientBG(context).colors.last;
    final backgroundColor = sisData.darkMode
        ? const Color(0xff101114)
        : Colors.white;
    // Width-based: phones keep the established bottom navigation while
    // tablet widths get a persistent NavigationRail with constrained
    // content instead of stretched phone UI.
    final isTablet = MediaQuery.sizeOf(context).width >= tabletBreakpoint;
    final content = Column(
      children: [
        Expanded(
          child: PageView(
            physics: const BouncingScrollPhysics(),
            controller: _pageController,
            onPageChanged: _onPageChanged,
            children: [
              const EventsScreen(),
              ResultsScreen(_showSee),
              const HomeScreen(),
              const AttendanceInfo(),
              const SettingsInfo(),
            ],
          ),
        ),
        ValueListenableBuilder<BackgroundSyncState>(
          valueListenable: backgroundSyncState,
          builder: (context, syncState, _) =>
              syncState == BackgroundSyncState.idle
              ? const SizedBox.shrink()
              : Theme(
                  data: Theme.of(context).copyWith(
                    colorScheme: ColorScheme.fromSeed(
                      seedColor: const Color(0xffba3237),
                      brightness: sisData.darkMode
                          ? Brightness.dark
                          : Brightness.light,
                    ),
                  ),
                  child: ColoredBox(
                    color: navColor,
                    child: const Padding(
                      // Natural height also accommodates multiline accessibility
                      // text without covering the scrollable page or navigation.
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Center(child: BackgroundSyncStatus()),
                    ),
                  ),
                ),
        ),
      ],
    );
    if (isTablet) {
      return Scaffold(
        backgroundColor: backgroundColor,
        body: SafeArea(
          child: Row(
            children: [
              ValueListenableBuilder<int>(
                valueListenable: Unified.screenNumber,
                builder: (context, selected, _) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(
                      MediaQuery.textScalerOf(
                        context,
                      ).scale(1).clamp(0.8, 1.15),
                    ),
                  ),
                  child: NavigationRail(
                    backgroundColor: navColor,
                    selectedIndex: selected,
                    onDestinationSelected: _selectPage,
                    labelType: NavigationRailLabelType.all,
                    selectedIconTheme: const IconThemeData(
                      color: Color(0xffba3237),
                      size: 29,
                    ),
                    unselectedIconTheme: IconThemeData(
                      color: sisData.darkMode ? Colors.white70 : Colors.black54,
                      size: 29,
                    ),
                    selectedLabelTextStyle: const TextStyle(
                      fontFamily: 'Comfortaa',
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: Color(0xffba3237),
                    ),
                    unselectedLabelTextStyle: TextStyle(
                      fontFamily: 'Comfortaa',
                      fontSize: 11,
                      color: sisData.darkMode ? Colors.white70 : Colors.black54,
                    ),
                    destinations: [
                      for (final destination in _destinations)
                        NavigationRailDestination(
                          icon: Icon(destination.icon),
                          selectedIcon: Icon(destination.activeIcon),
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: tabletMaxContentWidth,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // A number of the established screens scale spacing
                        // and type from MediaQuery.width. Once the rail takes
                        // space, that must be the content width rather than
                        // the physical display width.
                        final mediaQuery = MediaQuery.of(context);
                        return MediaQuery(
                          data: mediaQuery.copyWith(
                            size: Size(
                              constraints.maxWidth,
                              mediaQuery.size.height,
                            ),
                          ),
                          child: content,
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: backgroundColor,
      body: content,
      bottomNavigationBar: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(
            MediaQuery.textScalerOf(context).scale(1).clamp(0.8, 1.15),
          ),
        ),
        child: ValueListenableBuilder<int>(
          valueListenable: Unified.screenNumber,
          builder: (context, selected, _) => DecoratedBox(
            decoration: BoxDecoration(
              color: navColor,
            ),
            child: SafeArea(
              top: false,
              child: BottomNavigationBar(
                type: BottomNavigationBarType.fixed,
                backgroundColor: navColor,
                elevation: 0,
                currentIndex: selected,
                selectedItemColor: const Color(0xffba3237),
                unselectedItemColor: sisData.darkMode
                    ? Colors.white70
                    : Colors.black54,
                selectedFontSize: 11,
                unselectedFontSize: 11,
                iconSize: 29,
                selectedLabelStyle: const TextStyle(
                  fontFamily: 'Comfortaa',
                  fontWeight: FontWeight.bold,
                ),
                unselectedLabelStyle: const TextStyle(fontFamily: 'Comfortaa'),
                items: [
                  for (final destination in _destinations)
                    BottomNavigationBarItem(
                      icon: Icon(destination.icon),
                      activeIcon: Icon(destination.activeIcon),
                      label: destination.label,
                    ),
                ],
                onTap: _selectPage,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onPageChanged(int page) {
    _flushScreenDuration();
    Unified.screenNumber.value = page;
    _activeScreen = _screenNames[page];
    _screenEnteredAt = DateTime.now();
    unawaited(SyncDiagnostics.recordScreen(_screenNames[page]));
  }

  void _selectPage(int index) {
    _pageController.animateToPage(
      index,
      curve: Curves.easeOutCubic,
      duration: const Duration(milliseconds: 280),
    );
  }

  void _flushScreenDuration() {
    final screen = _activeScreen;
    final enteredAt = _screenEnteredAt;
    if (screen == null || enteredAt == null) return;
    _activeScreen = null;
    _screenEnteredAt = null;
    final duration = DateTime.now().difference(enteredAt).inMilliseconds;
    if (duration > 0) {
      unawaited(
        SyncDiagnostics.recordScreenDuration(
          screen: screen,
          durationMs: duration,
        ),
      );
    }
  }
}
