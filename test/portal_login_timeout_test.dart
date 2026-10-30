import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/portal_login_screen.dart';
import 'package:official_connect/Services/portal_session.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DisposeProbe extends StatefulWidget {
  const _DisposeProbe({required this.onDispose});

  final VoidCallback onDispose;

  @override
  State<_DisposeProbe> createState() => _DisposeProbeState();
}

class _DisposeProbeState extends State<_DisposeProbe> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SyncDiagnostics.configure((_, __) async {});
  });

  testWidgets(
    'a stalled browser shows a timeout instead of silently returning',
    (tester) async {
      final data = SisData();
      var browserDisposed = false;
      late ValueChanged<Uri?> capturedLoadStop;
      final events = <Map<String, Object>>[];
      SyncDiagnostics.configure((name, fields) async {
        if (name == 'sync_finished') events.add(fields);
      });
      late VoidCallback capturedNavigationStart;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: data,
          child: MaterialApp(
            home: PortalLoginScreen(
              browserBuilderForTesting:
                  ({
                    required onLoadStop,
                    required onReceivedError,
                    required onNavigationStart,
                    required onBrowserFailure,
                    required onReceivedHttpError,
                  }) {
                    capturedNavigationStart = onNavigationStart;
                    capturedLoadStop = onLoadStop;
                    return _DisposeProbe(
                      onDispose: () => browserDisposed = true,
                    );
                  },
            ),
          ),
        ),
      );
      capturedNavigationStart();
      await tester.pump(const Duration(seconds: 16));
      capturedLoadStop(PortalSession.loginUri);
      await tester.pump();
      expect(find.text('Unable to connect to the website'), findsOneWidget);
      expect(find.text('Back to sign in'), findsOneWidget);
      expect(browserDisposed, isTrue);
      expect(
        find.text(
          'The website is taking too long to respond. Please try again later.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(events, hasLength(1));
      expect(events.single['failure_reason'], 'timeout');
      expect(events.single['section'], 'dashboard');
      expect(events.single['failure_step'], 'authenticate');
      await tester.pumpWidget(const SizedBox());
      data.dispose();
    },
  );

  testWidgets('a loaded portal page cancels only the short connection timer', (
    tester,
  ) async {
    final data = SisData();
    final events = <Map<String, Object>>[];
    late ValueChanged<Uri?> capturedLoadStop;
    late VoidCallback capturedNavigationStart;
    SyncDiagnostics.configure((name, fields) async {
      if (name == 'sync_finished') events.add(fields);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: data,
        child: MaterialApp(
          home: PortalLoginScreen(
            browserBuilderForTesting:
                ({
                  required onLoadStop,
                  required onReceivedError,
                  required onNavigationStart,
                  required onBrowserFailure,
                  required onReceivedHttpError,
                }) {
                  capturedLoadStop = onLoadStop;
                  capturedNavigationStart = onNavigationStart;
                  return const SizedBox();
                },
          ),
        ),
      ),
    );
    capturedNavigationStart();
    capturedLoadStop(
      Uri.parse('https://parents.msrit.edu/newparents/dashboard.php'),
    );
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('Unable to connect to the website'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    expect(find.text('Sign-in took too long'), findsOneWidget);
    expect(events, hasLength(1));
    expect(events.single['failure_reason'], 'timeout');
    await tester.pumpWidget(const SizedBox());
    data.dispose();
  });

  testWidgets('native subresource errors are ignored; main frame fails fast', (
    tester,
  ) async {
    final data = SisData();
    final events = <Map<String, Object>>[];
    late ValueChanged<bool> capturedReceivedError;
    late VoidCallback capturedNavigationStart;
    late void Function({required bool isMainFrame, required int? statusCode})
    capturedHttpError;
    SyncDiagnostics.configure((name, fields) async {
      if (name == 'sync_finished') events.add(fields);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: data,
        child: MaterialApp(
          home: PortalLoginScreen(
            browserBuilderForTesting:
                ({
                  required onLoadStop,
                  required onReceivedError,
                  required onNavigationStart,
                  required onBrowserFailure,
                  required onReceivedHttpError,
                }) {
                  capturedReceivedError = onReceivedError;
                  capturedNavigationStart = onNavigationStart;
                  capturedHttpError = onReceivedHttpError;
                  return const SizedBox();
                },
          ),
        ),
      ),
    );
    capturedNavigationStart();
    capturedHttpError(isMainFrame: false, statusCode: 503);
    capturedReceivedError(false);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(events, isEmpty);
    capturedReceivedError(true);
    await tester.pump();
    expect(find.text('Unable to connect to the website'), findsOneWidget);
    expect(events, hasLength(1));
    expect(events.single['failure_reason'], 'network_error');
    await tester.pumpWidget(const SizedBox());
    data.dispose();
  });

  testWidgets('initial main-frame HTTP 503 fails once before load stop', (
    tester,
  ) async {
    final data = SisData();
    final finishedEvents = <Map<String, Object>>[];
    final syncFailureEvents = <Map<String, Object>>[];
    late VoidCallback capturedNavigationStart;
    late ValueChanged<Uri?> capturedLoadStop;
    late void Function({required bool isMainFrame, required int? statusCode})
    capturedHttpError;
    SyncDiagnostics.configure((name, fields) async {
      if (name == 'login_flow_finished') finishedEvents.add(fields);
      if (name == 'sync_finished') syncFailureEvents.add(fields);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: data,
        child: MaterialApp(
          home: PortalLoginScreen(
            browserBuilderForTesting:
                ({
                  required onLoadStop,
                  required onReceivedError,
                  required onNavigationStart,
                  required onBrowserFailure,
                  required onReceivedHttpError,
                }) {
                  capturedNavigationStart = onNavigationStart;
                  capturedLoadStop = onLoadStop;
                  capturedHttpError = onReceivedHttpError;
                  return const SizedBox();
                },
          ),
        ),
      ),
    );
    capturedNavigationStart();
    capturedHttpError(isMainFrame: true, statusCode: 503);
    capturedLoadStop(PortalSession.loginUri);
    capturedHttpError(isMainFrame: true, statusCode: 503);
    await tester.pump();
    expect(find.text('Unable to connect to the website'), findsOneWidget);
    expect(finishedEvents, hasLength(1));
    expect(finishedEvents.single['outcome'], 'error');
    expect(syncFailureEvents, hasLength(1));
    expect(syncFailureEvents.single['failure_reason'], 'request_error');
    expect(syncFailureEvents.single.containsKey('statusCode'), isFalse);
    expect(
      syncFailureEvents.single.keys.any((key) => key.contains('url')),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
    data.dispose();
  });

  testWidgets('HTTP errors after initial portal load are ignored', (
    tester,
  ) async {
    final data = SisData();
    final syncFailureEvents = <Map<String, Object>>[];
    late VoidCallback capturedNavigationStart;
    late ValueChanged<Uri?> capturedLoadStop;
    late void Function({required bool isMainFrame, required int? statusCode})
    capturedHttpError;
    SyncDiagnostics.configure((name, fields) async {
      if (name == 'sync_finished') syncFailureEvents.add(fields);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: data,
        child: MaterialApp(
          home: PortalLoginScreen(
            browserBuilderForTesting:
                ({
                  required onLoadStop,
                  required onReceivedError,
                  required onNavigationStart,
                  required onBrowserFailure,
                  required onReceivedHttpError,
                }) {
                  capturedNavigationStart = onNavigationStart;
                  capturedLoadStop = onLoadStop;
                  capturedHttpError = onReceivedHttpError;
                  return const SizedBox();
                },
          ),
        ),
      ),
    );
    capturedNavigationStart();
    capturedHttpError(isMainFrame: false, statusCode: 503);
    capturedLoadStop(
      Uri.parse('https://parents.msrit.edu/newparents/dashboard.php'),
    );
    capturedHttpError(isMainFrame: true, statusCode: 503);
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('Unable to connect to the website'), findsNothing);
    expect(syncFailureEvents, isEmpty);
    await tester.pumpWidget(const SizedBox());
    data.dispose();
  });

  testWidgets(
    'a silent post-page stall completes once and preserves cached data',
    (tester) async {
      final data = SisData();
      await data.loadDummyData();
      final marks = data.marks.length;
      final completions = <bool>[];
      late ValueChanged<Uri?> capturedLoadStop;
      late VoidCallback capturedNavigationStart;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: data,
          child: MaterialApp(
            home: PortalLoginScreen(
              silent: true,
              reuseSession: true,
              browserBuilderForTesting:
                  ({
                    required onLoadStop,
                    required onReceivedError,
                    required onNavigationStart,
                    required onBrowserFailure,
                    required onReceivedHttpError,
                  }) {
                    capturedLoadStop = onLoadStop;
                    capturedNavigationStart = onNavigationStart;
                    return const SizedBox();
                  },
              onFinished: completions.add,
            ),
          ),
        ),
      );
      capturedNavigationStart();
      capturedLoadStop(PortalSession.loginUri);
      await tester.pump(const Duration(seconds: 76));
      await tester.pump();
      expect(completions, [false]);
      expect(data.marks.length, marks);
      expect(data.isValidData, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(completions, [false]);
      data.dispose();
    },
  );

  testWidgets('startup delay is outside the 15-second connection window', (
    tester,
  ) async {
    final data = SisData();
    late VoidCallback capturedNavigationStart;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: data,
        child: MaterialApp(
          home: PortalLoginScreen(
            browserBuilderForTesting:
                ({
                  required onLoadStop,
                  required onReceivedError,
                  required onNavigationStart,
                  required onBrowserFailure,
                  required onReceivedHttpError,
                }) {
                  capturedNavigationStart = onNavigationStart;
                  return const SizedBox();
                },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Unable to connect to the website'), findsNothing);
    capturedNavigationStart();
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('Unable to connect to the website'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    data.dispose();
  });

  testWidgets(
    'external and about:blank pages do not satisfy portal navigation',
    (tester) async {
      final data = SisData();
      late VoidCallback capturedNavigationStart;
      late ValueChanged<Uri?> capturedLoadStop;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: data,
          child: MaterialApp(
            home: PortalLoginScreen(
              browserBuilderForTesting:
                  ({
                    required onLoadStop,
                    required onReceivedError,
                    required onNavigationStart,
                    required onBrowserFailure,
                    required onReceivedHttpError,
                  }) {
                    capturedNavigationStart = onNavigationStart;
                    capturedLoadStop = onLoadStop;
                    return const SizedBox();
                  },
            ),
          ),
        ),
      );
      capturedNavigationStart();
      capturedLoadStop(Uri.parse('about:blank'));
      capturedLoadStop(Uri.parse('https://login.example.com/newparents/home'));
      capturedLoadStop(Uri.parse('http://parents.msrit.edu/newparents/home'));
      capturedLoadStop(Uri.parse('https://parents.msrit.edu/login/home'));
      await tester.pump(const Duration(seconds: 16));
      expect(find.text('Unable to connect to the website'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      data.dispose();
    },
  );

  testWidgets('interactive pause and resume retain the 75-second deadline', (
    tester,
  ) async {
    final data = SisData();
    late VoidCallback capturedNavigationStart;
    late ValueChanged<Uri?> capturedLoadStop;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: data,
        child: MaterialApp(
          home: PortalLoginScreen(
            browserBuilderForTesting:
                ({
                  required onLoadStop,
                  required onReceivedError,
                  required onNavigationStart,
                  required onBrowserFailure,
                  required onReceivedHttpError,
                }) {
                  capturedNavigationStart = onNavigationStart;
                  capturedLoadStop = onLoadStop;
                  return const SizedBox();
                },
          ),
        ),
      ),
    );
    capturedNavigationStart();
    capturedLoadStop(
      Uri.parse('https://parents.msrit.edu/newparents/dashboard.php'),
    );
    await tester.pump(const Duration(seconds: 35));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 41));
    expect(find.text('Sign-in took too long'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    data.dispose();
  });

  testWidgets(
    'silent pause finishes once; resume and stale callbacks are ignored',
    (tester) async {
      final data = SisData();
      final completions = <bool>[];
      final finishedEvents = <Map<String, Object>>[];
      final routeActive = ValueNotifier(true);
      var browserDisposed = false;
      late VoidCallback capturedNavigationStart;
      late ValueChanged<Uri?> capturedLoadStop;
      late ValueChanged<bool> capturedReceivedError;
      SyncDiagnostics.configure((name, fields) async {
        if (name == 'login_flow_finished') finishedEvents.add(fields);
      });
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: data,
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: routeActive,
              builder: (context, active, _) => active
                  ? PortalLoginScreen(
                      silent: true,
                      onFinished: (result) {
                        completions.add(result);
                        routeActive.value = false;
                      },
                      browserBuilderForTesting:
                          ({
                            required onLoadStop,
                            required onReceivedError,
                            required onNavigationStart,
                            required onBrowserFailure,
                            required onReceivedHttpError,
                          }) {
                            capturedNavigationStart = onNavigationStart;
                            capturedLoadStop = onLoadStop;
                            capturedReceivedError = onReceivedError;
                            return _DisposeProbe(
                              onDispose: () => browserDisposed = true,
                            );
                          },
                    )
                  : const SizedBox(),
            ),
          ),
        ),
      );
      capturedNavigationStart();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(completions, [false]);
      expect(routeActive.value, isFalse);
      expect(browserDisposed, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      capturedLoadStop(
        Uri.parse('https://parents.msrit.edu/newparents/dashboard.php'),
      );
      capturedReceivedError(true);
      capturedNavigationStart();
      await tester.pump(const Duration(seconds: 20));
      expect(completions, [false]);
      expect(finishedEvents, hasLength(1));
      expect(finishedEvents.single['outcome'], 'cancelled');
      routeActive.dispose();
      data.dispose();
    },
  );

  testWidgets(
    'recoverable interactive browser failure leaves login unfinished',
    (tester) async {
      final data = SisData();
      final finishedEvents = <Map<String, Object>>[];
      late VoidCallback capturedNavigationStart;
      late ValueChanged<Object> capturedBrowserFailure;
      SyncDiagnostics.configure((name, fields) async {
        if (name == 'login_flow_finished') finishedEvents.add(fields);
      });
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: data,
          child: MaterialApp(
            home: PortalLoginScreen(
              browserBuilderForTesting:
                  ({
                    required onLoadStop,
                    required onReceivedError,
                    required onNavigationStart,
                    required onBrowserFailure,
                    required onReceivedHttpError,
                  }) {
                    capturedNavigationStart = onNavigationStart;
                    capturedBrowserFailure = onBrowserFailure;
                    return const SizedBox();
                  },
            ),
          ),
        ),
      );
      capturedNavigationStart();
      capturedBrowserFailure(StateError('temporary browser failure'));
      await tester.pump(const Duration(seconds: 16));
      expect(find.text('Unable to connect to the website'), findsNothing);
      expect(find.text('Show page'), findsOneWidget);
      expect(finishedEvents, isEmpty);
      await tester.tap(find.text('Show page'));
      await tester.pump();
      expect(find.text('Show page'), findsNothing);
      expect(finishedEvents, isEmpty);
      await tester.pumpWidget(const SizedBox());
      data.dispose();
    },
  );

  testWidgets('silent browser failure remains terminal and completes once', (
    tester,
  ) async {
    final data = SisData();
    final completions = <bool>[];
    final finishedEvents = <Map<String, Object>>[];
    late ValueChanged<Object> capturedBrowserFailure;
    SyncDiagnostics.configure((name, fields) async {
      if (name == 'login_flow_finished') finishedEvents.add(fields);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: data,
        child: MaterialApp(
          home: PortalLoginScreen(
            silent: true,
            onFinished: completions.add,
            browserBuilderForTesting:
                ({
                  required onLoadStop,
                  required onReceivedError,
                  required onNavigationStart,
                  required onBrowserFailure,
                  required onReceivedHttpError,
                }) {
                  capturedBrowserFailure = onBrowserFailure;
                  return const SizedBox();
                },
          ),
        ),
      ),
    );
    capturedBrowserFailure(StateError('browser failed'));
    await tester.pump();
    capturedBrowserFailure(StateError('late browser failure'));
    await tester.pump();
    expect(completions, [false]);
    expect(finishedEvents, hasLength(1));
    expect(finishedEvents.single['outcome'], 'error');
    await tester.pumpWidget(const SizedBox());
    data.dispose();
  });
}
