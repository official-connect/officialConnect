import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/portal_login_screen.dart';
import 'package:official_connect/Screens/login_screen/portal_refresh.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/portal_refresh_policy.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:official_connect/Widgets/background_sync_status.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _PortalScreenBuilder =
    Widget Function({required ValueChanged<PortalLoginOutcome> onOutcome});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'portal_usn': 'TEST0000',
      'portal_dob': '2000-01-01',
      'portal_verification_value': '0000',
    });
    FirebaseFeatureFlags.setValuesForTesting(const {
      'portal_sync_enabled': true,
    });
    setBackgroundSyncState(BackgroundSyncState.idle);
  });

  tearDown(() {
    FirebaseFeatureFlags.setValuesForTesting(const {});
    SyncDiagnostics.configure(null);
    setBackgroundSyncState(BackgroundSyncState.idle);
  });

  Future<void> pumpRefresh(
    WidgetTester tester, {
    required SisData sisData,
    required _PortalScreenBuilder portalScreenBuilder,
    bool automatic = false,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  FilledButton(
                    onPressed: () => openPortalRefresh(
                      context,
                      portalScreenBuilderForTesting: portalScreenBuilder,
                      automatic: automatic,
                    ),
                    child: const Text('Refresh'),
                  ),
                  const BackgroundSyncStatus(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    await tester.pump();
  }

  Future<
    ({
      ValueNotifier<bool> callerVisible,
      ValueChanged<PortalLoginOutcome> complete,
      Future<void> Function() waitForCompletion,
    })
  >
  startRefreshWithUnmountableCaller(
    WidgetTester tester, {
    required SisData sisData,
  }) async {
    final callerVisible = ValueNotifier(true);
    late ValueChanged<PortalLoginOutcome> completeChild;
    late Future<void> refreshFuture;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: callerVisible,
                  builder: (context, visible, _) => visible
                      ? Builder(
                          builder: (callerContext) => FilledButton(
                            onPressed: () {
                              refreshFuture = openPortalRefresh(
                                callerContext,
                                portalScreenBuilderForTesting:
                                    ({required onOutcome}) {
                                      completeChild = onOutcome;
                                      return const SizedBox();
                                    },
                              );
                            },
                            child: const Text('Refresh'),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: BackgroundSyncStatus(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    await tester.pump();
    callerVisible.value = false;
    await tester.pump();
    return (
      callerVisible: callerVisible,
      complete: (outcome) => completeChild(outcome),
      waitForCompletion: () => refreshFuture,
    );
  }

  Widget _silentPortal(
    ValueChanged<PortalLoginOutcome> onOutcome, {
    required Widget Function({
      required ValueChanged<Uri?> onLoadStop,
      required ValueChanged<bool> onReceivedError,
      required VoidCallback onNavigationStart,
      required ValueChanged<Object> onBrowserFailure,
      required void Function({
        required bool isMainFrame,
        required int? statusCode,
      })
      onReceivedHttpError,
    })
    browserBuilder,
  }) => PortalLoginScreen(
    silent: true,
    onOutcome: onOutcome,
    browserBuilderForTesting: browserBuilder,
  );

  testWidgets('app-pause cancellation is quiet and recorded distinctly', (
    tester,
  ) async {
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, values) async {
      if (name == 'refresh_finished') events.add({'name': name, ...values});
    });
    await SyncDiagnostics.setEnabled(true);
    final sisData = SisData();
    addTearDown(sisData.dispose);

    await pumpRefresh(
      tester,
      sisData: sisData,
      portalScreenBuilder: ({required onOutcome}) => _silentPortal(
        onOutcome,
        browserBuilder:
            ({
              required onLoadStop,
              required onReceivedError,
              required onNavigationStart,
              required onBrowserFailure,
              required onReceivedHttpError,
            }) => const SizedBox(),
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(find.text('Could not refresh in the background.'), findsNothing);
    expect(find.text('Update needs attention'), findsNothing);
    expect(find.text('Refresh'), findsOneWidget);
    expect(backgroundSyncState.value, BackgroundSyncState.idle);
    expect(events, hasLength(1));
    expect(events.single['outcome'], 'cancelled');
  });

  testWidgets('connection refusal stays an error with retry guidance', (
    tester,
  ) async {
    final sisData = SisData();
    addTearDown(sisData.dispose);
    late VoidCallback navigationStart;
    late ValueChanged<bool> receivedError;

    await pumpRefresh(
      tester,
      sisData: sisData,
      portalScreenBuilder: ({required onOutcome}) => _silentPortal(
        onOutcome,
        browserBuilder:
            ({
              required onLoadStop,
              required onReceivedError,
              required onNavigationStart,
              required onBrowserFailure,
              required onReceivedHttpError,
            }) {
              navigationStart = onNavigationStart;
              receivedError = onReceivedError;
              return const SizedBox();
            },
      ),
    );
    navigationStart();
    receivedError(true);
    await tester.pumpAndSettle();

    expect(backgroundSyncState.value, BackgroundSyncState.error);
    expect(find.text('Update needs attention'), findsOneWidget);
    expect(find.textContaining('Could not reach the website.'), findsOneWidget);
    expect(
      find.textContaining('saved information is still available'),
      findsOneWidget,
    );
    expect(find.text('Open sync'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('silent HTTP 403 is not classified as a connection failure', (
    tester,
  ) async {
    final sisData = SisData();
    addTearDown(sisData.dispose);
    late VoidCallback navigationStart;
    late void Function({required bool isMainFrame, required int? statusCode})
    receivedHttpError;

    await pumpRefresh(
      tester,
      sisData: sisData,
      portalScreenBuilder: ({required onOutcome}) => _silentPortal(
        onOutcome,
        browserBuilder:
            ({
              required onLoadStop,
              required onReceivedError,
              required onNavigationStart,
              required onBrowserFailure,
              required onReceivedHttpError,
            }) {
              navigationStart = onNavigationStart;
              receivedHttpError = onReceivedHttpError;
              return const SizedBox();
            },
      ),
    );
    navigationStart();
    receivedHttpError(isMainFrame: true, statusCode: 403);
    await tester.pumpAndSettle();

    expect(backgroundSyncState.value, BackgroundSyncState.error);
    expect(
      find.textContaining('Could not refresh in the background.'),
      findsOneWidget,
    );
    expect(find.textContaining('Could not reach the website.'), findsNothing);
    expect(find.text('Refresh'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('child timeout remains an error with timeout-specific guidance', (
    tester,
  ) async {
    final sisData = SisData();
    addTearDown(sisData.dispose);

    await pumpRefresh(
      tester,
      sisData: sisData,
      portalScreenBuilder: ({required onOutcome}) => _silentPortal(
        onOutcome,
        browserBuilder:
            ({
              required onLoadStop,
              required onReceivedError,
              required onNavigationStart,
              required onBrowserFailure,
              required onReceivedHttpError,
            }) => const SizedBox(),
      ),
    );
    await tester.pump(const Duration(seconds: 76));
    await tester.pumpAndSettle();

    expect(backgroundSyncState.value, BackgroundSyncState.error);
    expect(
      find.textContaining('The website took too long to respond.'),
      findsOneWidget,
    );
    expect(find.text('Open sync'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('late duplicate overlay completion is ignored', (tester) async {
    final sisData = SisData();
    addTearDown(sisData.dispose);
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, values) async {
      if (name == 'refresh_finished') events.add({'name': name, ...values});
    });
    await SyncDiagnostics.setEnabled(true);
    late ValueChanged<PortalLoginOutcome> completeChild;

    await pumpRefresh(
      tester,
      sisData: sisData,
      portalScreenBuilder: ({required onOutcome}) {
        completeChild = onOutcome;
        return const SizedBox();
      },
    );
    completeChild(PortalLoginOutcome.cancelled);
    completeChild(PortalLoginOutcome.networkError);
    await tester.pump();

    expect(events, hasLength(1));
    expect(events.single['outcome'], 'cancelled');
    expect(backgroundSyncState.value, BackgroundSyncState.idle);
    expect(find.text('Update needs attention'), findsNothing);
  });

  testWidgets('successful overlay completion emits one success outcome', (
    tester,
  ) async {
    final sisData = SisData();
    addTearDown(sisData.dispose);
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, values) async {
      if (name == 'refresh_finished') events.add({'name': name, ...values});
    });
    await SyncDiagnostics.setEnabled(true);
    late ValueChanged<PortalLoginOutcome> completeChild;

    await pumpRefresh(
      tester,
      sisData: sisData,
      portalScreenBuilder: ({required onOutcome}) {
        completeChild = onOutcome;
        return const SizedBox();
      },
    );
    completeChild(PortalLoginOutcome.success);
    await tester.pumpAndSettle();

    expect(events, hasLength(1));
    expect(events.single['outcome'], 'success');
    expect(backgroundSyncState.value, BackgroundSyncState.success);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('success applies refresh outcome after caller context unmounts', (
    tester,
  ) async {
    final sisData = SisData();
    addTearDown(sisData.dispose);
    final events = <Map<String, Object>>[];
    SyncDiagnostics.configure((name, values) async {
      if (name == 'refresh_finished') events.add({'name': name, ...values});
    });
    await SyncDiagnostics.setEnabled(true);
    final refresh = await startRefreshWithUnmountableCaller(
      tester,
      sisData: sisData,
    );
    addTearDown(refresh.callerVisible.dispose);

    refresh.complete(PortalLoginOutcome.success);
    await refresh.waitForCompletion();
    await tester.pump();

    expect(backgroundSyncState.value, BackgroundSyncState.success);
    expect(find.text('Updated'), findsOneWidget);
    expect(events, hasLength(1));
    expect(events.single['outcome'], 'success');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'cancellation applies refresh outcome after caller context unmounts',
    (tester) async {
      final sisData = SisData();
      addTearDown(sisData.dispose);
      final events = <Map<String, Object>>[];
      SyncDiagnostics.configure((name, values) async {
        if (name == 'refresh_finished') events.add({'name': name, ...values});
      });
      await SyncDiagnostics.setEnabled(true);
      final refresh = await startRefreshWithUnmountableCaller(
        tester,
        sisData: sisData,
      );
      addTearDown(refresh.callerVisible.dispose);

      refresh.complete(PortalLoginOutcome.cancelled);
      await refresh.waitForCompletion();
      await tester.pump();

      expect(backgroundSyncState.value, BackgroundSyncState.idle);
      expect(find.text('Update needs attention'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(events, hasLength(1));
      expect(events.single['outcome'], 'cancelled');
    },
  );

  testWidgets('automatic cooldown skips the browser and records one backoff', (
    tester,
  ) async {
    final data = SisData();
    addTearDown(data.dispose);
    final policy = PortalRefreshPolicy();
    await policy.recordOutcome(PortalRefreshPolicyOutcome.networkError);
    final outcomes = <String>[];
    SyncDiagnostics.configure((name, values) async {
      if (name == 'refresh_finished') outcomes.add(values['outcome'] as String);
    });
    await SyncDiagnostics.setEnabled(true);
    var created = false;
    await pumpRefresh(
      tester,
      sisData: data,
      automatic: true,
      portalScreenBuilder: ({required onOutcome}) {
        created = true;
        return const SizedBox();
      },
    );
    expect(created, isFalse);
    expect(outcomes, ['backoff']);
    expect(backgroundSyncState.value, BackgroundSyncState.idle);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('manual refresh bypasses cooldown and success clears it', (
    tester,
  ) async {
    final data = SisData();
    addTearDown(data.dispose);
    final policy = PortalRefreshPolicy();
    await policy.recordOutcome(PortalRefreshPolicyOutcome.timeout);
    late ValueChanged<PortalLoginOutcome> complete;
    await pumpRefresh(
      tester,
      sisData: data,
      portalScreenBuilder: ({required onOutcome}) {
        complete = onOutcome;
        return const SizedBox();
      },
    );
    complete(PortalLoginOutcome.success);
    await tester.pumpAndSettle();
    expect(await policy.shouldSkip(automatic: true), isFalse);
    expect(backgroundSyncState.value, BackgroundSyncState.success);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('silent login still calls existing bool and typed callbacks', (
    tester,
  ) async {
    final sisData = SisData();
    addTearDown(sisData.dispose);
    final outcomes = <PortalLoginOutcome>[];
    final legacyResults = <bool>[];
    late VoidCallback navigationStart;
    late ValueChanged<bool> receivedError;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sisData,
        child: MaterialApp(
          home: PortalLoginScreen(
            silent: true,
            onOutcome: outcomes.add,
            onFinished: legacyResults.add,
            browserBuilderForTesting:
                ({
                  required onLoadStop,
                  required onReceivedError,
                  required onNavigationStart,
                  required onBrowserFailure,
                  required onReceivedHttpError,
                }) {
                  navigationStart = onNavigationStart;
                  receivedError = onReceivedError;
                  return const SizedBox();
                },
          ),
        ),
      ),
    );

    navigationStart();
    receivedError(true);
    await tester.pump();
    expect(outcomes, [PortalLoginOutcome.networkError]);
    expect(legacyResults, [false]);
  });
}
