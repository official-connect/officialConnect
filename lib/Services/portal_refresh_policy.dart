import 'package:shared_preferences/shared_preferences.dart';

/// Bounded outcomes used by the automatic portal refresh backoff policy.
enum PortalRefreshPolicyOutcome {
  success,
  networkError,
  timeout,
  updateError,
  cancelled,
  disabled,
}

/// Persists a short automatic-refresh pause after a portal failure.
///
/// The stored value is only the epoch-millisecond time of the last failure;
/// it contains no account, device, or failure details. Manual refreshes should
/// call [shouldSkip] with `automatic: false` and remain available during the
/// automatic cooldown.
class PortalRefreshPolicy {
  PortalRefreshPolicy({
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? clock,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  static const cooldown = Duration(minutes: 15);
  static const _failureTimestampKey = 'portal_auto_refresh_failure_at_ms';

  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _clock;

  /// Returns true only when an automatic retry is still inside the cooldown.
  /// Invalid or future timestamps are discarded so they cannot lock refreshes.
  Future<bool> shouldSkip({required bool automatic}) async {
    if (!automatic) return false;

    try {
      final prefs = await _preferences();
      final stored = prefs.get(_failureTimestampKey);
      final now = _clock().millisecondsSinceEpoch;
      if (stored is! int || stored <= 0 || stored > now) {
        if (stored != null) await prefs.remove(_failureTimestampKey);
        return false;
      }

      final age = now - stored;
      if (age < cooldown.inMilliseconds) return true;

      await prefs.remove(_failureTimestampKey);
    } catch (_) {
      // Backoff persistence must not prevent a refresh from being attempted.
    }
    return false;
  }

  /// Records only outcomes that should change automatic retry behavior.
  /// Cancellation and disabled states neither start nor extend the cooldown.
  Future<void> recordOutcome(PortalRefreshPolicyOutcome outcome) async {
    try {
      final prefs = await _preferences();
      if (outcome == PortalRefreshPolicyOutcome.success) {
        await prefs.remove(_failureTimestampKey);
      } else if (outcome == PortalRefreshPolicyOutcome.networkError ||
          outcome == PortalRefreshPolicyOutcome.timeout ||
          outcome == PortalRefreshPolicyOutcome.updateError) {
        final timestamp = _clock().millisecondsSinceEpoch;
        if (timestamp > 0) {
          await prefs.setInt(_failureTimestampKey, timestamp);
        } else {
          await prefs.remove(_failureTimestampKey);
        }
      }
    } catch (_) {
      // Refresh results should be delivered even if preferences are unavailable.
    }
  }
}
