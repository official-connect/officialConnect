import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Services/portal_refresh_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime now;
  late PortalRefreshPolicy policy;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime.utc(2026, 10, 30, 12);
    policy = PortalRefreshPolicy(clock: () => now);
  });

  test('failure timestamp is anonymous and pauses automatic refresh', () async {
    await policy.recordOutcome(PortalRefreshPolicyOutcome.networkError);
    final prefs = await SharedPreferences.getInstance();

    expect(prefs.getKeys(), {'portal_auto_refresh_failure_at_ms'});
    expect(
      prefs.get('portal_auto_refresh_failure_at_ms'),
      now.millisecondsSinceEpoch,
    );
    expect(await policy.shouldSkip(automatic: true), isTrue);
    expect(await policy.shouldSkip(automatic: false), isFalse);
  });

  test('each configured failure starts the automatic cooldown', () async {
    for (final outcome in const [
      PortalRefreshPolicyOutcome.networkError,
      PortalRefreshPolicyOutcome.timeout,
      PortalRefreshPolicyOutcome.updateError,
    ]) {
      SharedPreferences.setMockInitialValues({});
      policy = PortalRefreshPolicy(clock: () => now);
      await policy.recordOutcome(outcome);
      expect(
        await policy.shouldSkip(automatic: true),
        isTrue,
        reason: '$outcome',
      );
    }
  });

  test(
    'cancellation and disabled outcomes do not create or extend cooldown',
    () async {
      await policy.recordOutcome(PortalRefreshPolicyOutcome.cancelled);
      await policy.recordOutcome(PortalRefreshPolicyOutcome.disabled);
      expect(await policy.shouldSkip(automatic: true), isFalse);

      await policy.recordOutcome(PortalRefreshPolicyOutcome.timeout);
      final prefs = await SharedPreferences.getInstance();
      final original = prefs.get('portal_auto_refresh_failure_at_ms');
      now = now.add(const Duration(minutes: 3));
      await policy.recordOutcome(PortalRefreshPolicyOutcome.cancelled);
      await policy.recordOutcome(PortalRefreshPolicyOutcome.disabled);
      expect(prefs.get('portal_auto_refresh_failure_at_ms'), original);
    },
  );

  test('success clears an existing failure timestamp', () async {
    await policy.recordOutcome(PortalRefreshPolicyOutcome.updateError);
    expect(await policy.shouldSkip(automatic: true), isTrue);

    await policy.recordOutcome(PortalRefreshPolicyOutcome.success);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.get('portal_auto_refresh_failure_at_ms'), isNull);
    expect(await policy.shouldSkip(automatic: true), isFalse);
  });

  test(
    'cooldown expires at fifteen minutes and allows the next automatic try',
    () async {
      await policy.recordOutcome(PortalRefreshPolicyOutcome.timeout);
      now = now.add(const Duration(minutes: 14, seconds: 59));
      expect(await policy.shouldSkip(automatic: true), isTrue);

      now = now.add(const Duration(seconds: 1));
      expect(await policy.shouldSkip(automatic: true), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.get('portal_auto_refresh_failure_at_ms'), isNull);
    },
  );

  test('failure cooldown survives a policy instance restart', () async {
    await policy.recordOutcome(PortalRefreshPolicyOutcome.networkError);
    final restartedPolicy = PortalRefreshPolicy(clock: () => now);

    expect(await restartedPolicy.shouldSkip(automatic: true), isTrue);
  });

  test(
    'future timestamps are removed and do not permanently block refresh',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'portal_auto_refresh_failure_at_ms',
        now.add(const Duration(days: 365)).millisecondsSinceEpoch,
      );

      expect(await policy.shouldSkip(automatic: true), isFalse);
      expect(prefs.get('portal_auto_refresh_failure_at_ms'), isNull);
    },
  );

  test('malformed and nonpositive timestamps are removed', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('portal_auto_refresh_failure_at_ms', 'not-a-time');
    expect(await policy.shouldSkip(automatic: true), isFalse);
    expect(prefs.get('portal_auto_refresh_failure_at_ms'), isNull);

    await prefs.setInt('portal_auto_refresh_failure_at_ms', -1);
    expect(await policy.shouldSkip(automatic: true), isFalse);
    expect(prefs.get('portal_auto_refresh_failure_at_ms'), isNull);
  });

  test(
    'preference errors fail open and do not fail outcome delivery',
    () async {
      final unavailable = PortalRefreshPolicy(
        clock: () => now,
        preferences: () async => throw StateError('preferences unavailable'),
      );

      expect(await unavailable.shouldSkip(automatic: true), isFalse);
      await expectLater(
        unavailable.recordOutcome(PortalRefreshPolicyOutcome.timeout),
        completes,
      );
    },
  );
}
