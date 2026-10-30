import 'dart:async';

import 'package:flutter/material.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/login_screen.dart';
import 'package:official_connect/Screens/login_screen/portal_login_screen.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/portal_refresh_policy.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

bool _portalRefreshInFlight = false;

enum BackgroundSyncState { idle, updating, success, partial, error }

/// Lightweight app-wide state for the status chip shown above navigation.
/// It deliberately lives with the refresh coordinator so screens do not need
/// to maintain separate loading flags or block their own content.
final ValueNotifier<BackgroundSyncState> backgroundSyncState = ValueNotifier(
  BackgroundSyncState.idle,
);

Timer? _statusTimer;

void setBackgroundSyncState(
  BackgroundSyncState state, {
  Duration visibleFor = const Duration(seconds: 3),
}) {
  _statusTimer?.cancel();
  backgroundSyncState.value = state;
  if (state != BackgroundSyncState.idle &&
      state != BackgroundSyncState.updating) {
    _statusTimer = Timer(visibleFor, () {
      backgroundSyncState.value = BackgroundSyncState.idle;
    });
  }
}

/// Refreshes portal data in place: the authenticated portal flow runs
/// off-screen and a small notification reports the outcome. Falls back to
/// the full sync page when no saved login exists or the background sync
/// needs user attention.
Future<void> openPortalRefresh(
  BuildContext context, {
  bool allowInteractiveFallback = true,
  bool automatic = false,
  @visibleForTesting
  Widget Function({required ValueChanged<PortalLoginOutcome> onOutcome})?
  portalScreenBuilderForTesting,
}) async {
  if (_portalRefreshInFlight) {
    unawaited(SyncDiagnostics.recordRefreshOutcome('in_flight'));
    return;
  }
  _portalRefreshInFlight = true;
  try {
    final messenger = ScaffoldMessenger.of(context);
    if (!FirebaseFeatureFlags.portalSyncEnabled) {
      unawaited(SyncDiagnostics.recordRefreshOutcome('disabled'));
      if (allowInteractiveFallback) {
        messenger.showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              'Updates are temporarily unavailable. Your saved information is still here.',
            ),
          ),
        );
      }
      return;
    }
    final retryPolicy = PortalRefreshPolicy();
    if (await retryPolicy.shouldSkip(automatic: automatic)) {
      unawaited(SyncDiagnostics.recordRefreshOutcome('backoff'));
      return;
    }
    if (!context.mounted) return;
    Future<void> openFullSyncPage() => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const LoginScreen(closeAfterSync: true),
      ),
    );

    final sisData = Provider.of<SisData>(context, listen: false);
    late final String usn;
    late final String dob;
    late final String verificationType;
    late final String verificationValue;
    final prefs = await SharedPreferences.getInstance();
    usn = prefs.getString('portal_usn') ?? '';
    dob = prefs.getString('portal_dob') ?? '';
    verificationType =
        prefs.getString('portal_verification_type') ?? "Father's mobile number";
    verificationValue = prefs.getString('portal_verification_value') ?? '';
    if (!context.mounted) return;

    // Without a complete saved login the user must review the form, so keep
    // the original full-page flow.
    if (usn.isEmpty || dob.isEmpty || verificationValue.isEmpty) {
      unawaited(SyncDiagnostics.recordRefreshOutcome('missing_login'));
      if (allowInteractiveFallback) await openFullSyncPage();
      return;
    }
    setBackgroundSyncState(BackgroundSyncState.updating);

    late final PortalLoginOutcome outcome;
    if (portalScreenBuilderForTesting == null &&
        usn.trim().toUpperCase() == 'DUMMY') {
      await sisData.loadDummyData();
      outcome = PortalLoginOutcome.success;
    } else {
      // Keep the WebView in a pointer-transparent overlay so cached data and
      // bottom navigation remain usable during the refresh.
      final completion = Completer<PortalLoginOutcome>();
      late final OverlayEntry entry;
      void complete(PortalLoginOutcome result) {
        if (completion.isCompleted) return;
        if (entry.mounted) entry.remove();
        completion.complete(result);
      }

      entry = OverlayEntry(
        builder: (_) => IgnorePointer(
          child:
              portalScreenBuilderForTesting?.call(onOutcome: complete) ??
              PortalLoginScreen(
                silent: true,
                initialUsn: usn.trim().toUpperCase(),
                initialDob: dob,
                initialVerificationType: verificationType,
                initialVerificationValue: verificationValue,
                reuseSession:
                    sisData.hasData &&
                    sisData.usn.trim().toUpperCase() ==
                        usn.trim().toUpperCase(),
                onOutcome: complete,
              ),
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(entry);
      outcome = await completion.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          if (entry.mounted) entry.remove();
          return PortalLoginOutcome.timeout;
        },
      );
    }
    await retryPolicy.recordOutcome(switch (outcome) {
      PortalLoginOutcome.success => PortalRefreshPolicyOutcome.success,
      PortalLoginOutcome.cancelled => PortalRefreshPolicyOutcome.cancelled,
      PortalLoginOutcome.timeout => PortalRefreshPolicyOutcome.timeout,
      PortalLoginOutcome.networkError =>
        PortalRefreshPolicyOutcome.networkError,
      PortalLoginOutcome.updateError => PortalRefreshPolicyOutcome.updateError,
      PortalLoginOutcome.disabled => PortalRefreshPolicyOutcome.disabled,
    });

    if (outcome == PortalLoginOutcome.success) {
      final attendanceStatus = sisData.syncStatusFor('attendance');
      final attendanceNeedsAttention =
          attendanceStatus == 'partial' || attendanceStatus == 'error';
      final hasIssues = sisData.hasSyncIssues;
      unawaited(
        SyncDiagnostics.recordRefreshOutcome(hasIssues ? 'partial' : 'success'),
      );
      setBackgroundSyncState(
        hasIssues ? BackgroundSyncState.partial : BackgroundSyncState.success,
      );
      if (!context.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
            content: Text(
              attendanceNeedsAttention
                  ? 'Attendance could not be fully updated. Previously saved attendance is still available.'
                  : hasIssues
                  ? 'Some information could not be updated. Previously saved information is still available.'
                  : 'Your information is up to date.',
            ),
            action: attendanceNeedsAttention && allowInteractiveFallback
                ? SnackBarAction(
                    label: 'Open sync',
                    onPressed: () {
                      if (context.mounted) openFullSyncPage();
                    },
                  )
                : null,
          ),
        );
    } else if (outcome == PortalLoginOutcome.cancelled) {
      // A user/app lifecycle interruption is not a portal failure. Leave the
      // saved information and its screen status undisturbed.
      unawaited(SyncDiagnostics.recordRefreshOutcome('cancelled'));
      setBackgroundSyncState(BackgroundSyncState.idle);
    } else if (outcome == PortalLoginOutcome.disabled) {
      unawaited(SyncDiagnostics.recordRefreshOutcome('disabled'));
      setBackgroundSyncState(BackgroundSyncState.idle);
      if (allowInteractiveFallback) {
        if (!context.mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              'Updates are temporarily unavailable. Your saved information is still here.',
            ),
          ),
        );
      }
    } else {
      unawaited(
        SyncDiagnostics.recordRefreshOutcome(
          outcome == PortalLoginOutcome.timeout ? 'timeout' : 'error',
        ),
      );
      setBackgroundSyncState(BackgroundSyncState.error);
      if (!allowInteractiveFallback || !context.mounted) return;
      final message = switch (outcome) {
        PortalLoginOutcome.networkError =>
          'Could not reach the website. Your saved information is still available. Please check your connection and try again later.',
        PortalLoginOutcome.timeout =>
          'The website took too long to respond. Your saved information is still available. Please try again later.',
        _ =>
          'Could not refresh in the background. Your saved information is still available.',
      };
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
            content: Text(message),
            action: SnackBarAction(
              label: 'Open sync',
              onPressed: () {
                if (context.mounted) openFullSyncPage();
              },
            ),
          ),
        );
    }
  } finally {
    _portalRefreshInFlight = false;
    if (backgroundSyncState.value == BackgroundSyncState.updating) {
      setBackgroundSyncState(BackgroundSyncState.error);
    }
  }
}
