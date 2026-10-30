# Update diagnostics

OfficialConnect records aggregate update health in Firebase Analytics. Events
must never contain student identifiers, dates of birth, verification values,
names, contact details, subjects, marks, URLs, cookies, page HTML, or raw error
messages.

## Events

`sync_section` records:

- section: profile, attendance, marks, results, fees, proctor, timetable,
  or seating
- outcome: ok, empty, partial, or error
- item_count, attempted_count, and failed_count
- duration_ms, duration_bucket, sync_mode, parser_version, and
  failure_reason (on failures)

`sync_finished` records the overall outcome, section count, duration, mode, and
parser version. Values are allow-listed and bounded before they reach the
analytics provider.

Users can disable this collection under **Settings > Help improve the app**.
The Android manifest explicitly removes advertising-ID permission.

## Support links in Settings and Explore

Settings provides Share feedback, Report a bug, Source code and (Android only)
Rate the app. Explore's feedback action uses the same destination and event
contract. URLs are defined in `lib/Services/app_support.dart`.

`support_action` records one intent event (`outcome=tapped`) and one external
launch result (`outcome=opened` or `error`) per action. Parameters:

- `action`: `app_feedback`, `report_bug`, `source_code`, or `rate_app`.
- `source_screen`: explicit allowlisted entry point, currently `settings` or
  `explore`, independent of the previous screen recorded by analytics.
- `outcome`: `tapped`, `opened`, or `error`.
- `duration_ms`: bounded external-link launch latency, only on the outcome
  event. This is **not** time spent completing the external form or review.
- Existing `app_version`, `release_cohort`, and `platform` context.

Successful launches also record `feature_opened` with the corresponding feature
and source screen. Do not add these two event types together as a count of uses.
For intent count, filter `support_action` by `outcome=tapped`; for handoff success
rate compare `opened` with `opened + error`. Use Analytics' user counts for
affected users rather than treating event totals as unique users.

These events never contain URLs, free text, form answers, report contents,
student identifiers, review text or star ratings. A browser/store accepting a
link does not establish a submission or even that the destination loaded.
Diagnostics opt-out suppresses collection while links remain usable. Analytics
delivery is not awaited by navigation, so unavailable analytics cannot block
support actions.

For GA4 exploration, register event-scoped custom dimensions for `action`,
`source_screen` and `outcome` if they do not already exist. Verify the event
sequence with synthetic data in DebugView before publishing; do not mark
`opened` as a submitted survey, bug report, or review conversion. This change
does not configure live GA4 dimensions or deploy an app build.

Automatic survey/review reminders remain tracked in GitHub issues #42 and #43.
The Settings links are always available, with no automatic prompt or inference
that a user has completed a form or posted a rating.

## Firebase setup

The Android and iOS apps are registered in the existing `unofficialconnect`
Firebase project. To refresh or replace that configuration:

1. Sign in with Firebase CLI and select or create the OfficialConnect project.
2. Run `flutterfire configure` for Android and iOS.
3. Enable Google Analytics for that Firebase project.
4. Build release artifacts with the production markers
   (`OFFICIAL_CONNECT_DISTRIBUTION=production` and the pubspec
   `APP_VERSION`). The `Release` workflow passes both automatically; for a
   local manual build use `scripts/android_release_check.sh
   --build-current`, which does the same. Builds made without that marker
   are intentionally excluded from production Analytics and Crashlytics,
   even when compiled in release mode.
5. Verify events in Analytics DebugView using dummy data before release.
6. Complete the Play Data safety form and publish a privacy policy that covers
   update diagnostics and the local student-data cache.

The `distribution_channel=production` user property is attached to production
Analytics data. This makes release dashboards easier to audit without sending
student or device identifiers from application code.
