# Integration reliability audit — 29 October 2026

## What was reproduced and improved

1. A new lifecycle regression test initially failed: leaving `LoadingScreen`
   before its 700 ms delay caused navigation through an unmounted context.
   A mounted check now prevents the stale navigation; the test then passed.
2. The login timeout left its hidden native browser in the widget tree while
   displaying the error. Timeout now removes that subtree. The widget regression
   asserts browser disposal while retaining the visible connection message.
   This reduces unnecessary browser lifetime, but is not proof of a fix for
   the production native ANRs.
3. Release artifact validation now rejects missing Flutter native libraries per
   packaged ABI, including an AAB whose optional feature module contains the
   library but whose base module does not. Review also added release-only
   `libapp.so` checks and rejection of failed/malformed ELF inspection. No
   speculative manifest or ABI-filter changes were made.

## Test scope

The Android integration suite uses the real native SharedPreferences and
Android WebView plugins on `emulator-5554`, with synthetic bundled data and
local HTML. It backs up and restores preferences without logging their values.
No physical or television device is used.

- Restore saved marks while the telemetry acknowledgement remains pending.
- Navigate all five destinations while the background update indicator runs;
  assert the selected destination changes for each tap.
- Preserve good marks after a malformed refresh and restore them through a new
  provider using real native preference storage.
- Read a local DOM with JavaScript and dispose/recreate the real Android
  WebView three times, including the production hidden browser viewport.

Phone dimensions are 412×915 logical pixels; tablet dimensions are 800×1280 on
the same Android emulator. These are emulator coverage, not physical-device
certification. The existing UI smoke suite additionally exercises 320×640,
412×915 and 800×1280 in both themes.

## Validation

- Full Flutter suite: 172 tests passed, including the new startup lifecycle
  regression and existing cache, timeout, scraping, offline and UI smoke tests.
- Packaging validators: 13 synthetic archive and fake-readelf tests passed.
- The freshly built release APK passed library presence checks for both
  `libflutter.so` and `libapp.so` on arm64-v8a, armeabi-v7a and x86_64, along
  with 16 KB ELF and APK ZIP alignment checks.
- Final native integration runs: three tests passed on phone (15 seconds) and
  three on tablet (17 seconds), including selected-destination assertions and
  the hidden browser viewport. Times exclude building and installation.
- Flutter analysis: no issues found. Screenshot smoke suite: nine tests passed,
  with synthetic-data captures under ignored `build/ui-smoke/`.
- Retained emulator AndroidRuntime/ActivityManager error logs contained zero
  fatal-exception markers and zero app-specific ANR markers when inspected.
- A newly built normal release APK succeeded (74.6 MB). The first attempts with
  `--no-pub` failed because the generated Java plugin registrant still referenced
  the integration-test plugin. A normal build with dependency/plugin generation
  enabled succeeded. This build-mode transition is a tooling issue, not an
  observed production crash.
- Independent review covered the lifecycle guards, timeout/browser disposal,
  integration assertions, and artifact validation. Two validator findings were
  patched; the final read-only review found no further actionable issues.
- The normal debug APK also built, was installed explicitly on emulator-5554,
  and opened to the native sign-in landing screen. The emulator was returned to
  phone dimensions, replacing the instrumented test build.

Reproduce with:

```sh
flutter test --no-pub
flutter analyze --no-pub
flutter test integration_test/reliability_test.dart -d emulator-5554
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

Set the desired emulator dimensions before each integration run. The test
runner installs an instrumented test build; build the normal APK afterward with
`flutter build apk --debug` or `flutter build apk --release`. Allow dependency
and plugin registration refresh when switching between integration and normal
builds; do not reuse a stale test registrant through `--no-pub`.

## Production evidence and limits

See [the live Crashlytics check](CRASHLYTICS_CHECK_2026-10-29.md) for the five
fatal startup events / one user and four ANRs / four users. The five fatal
events were on 1.1.5 (14), while one platform-channel ANR is confirmed on
1.1.7 (16). A missing native engine library fails before Dart starts; a Dart
login patch cannot catch or repair that installation at runtime.

The current-release ANR stack includes a native WebView favicon callback.
The installed plugin does not expose a supported option to suppress that
native callback. Browser lifetime mitigation and native integration tests are
useful, but cannot establish that the production ANR is eliminated.

The live portal remained unreachable at the final check (TCP connect timed out
after six seconds, HTTP 000). Synthetic
integration tests are not a successful live authenticated scrape. The large
historical scraping/unknown bucket remains incompletely diagnosed. GA4 was
unavailable through the current resolver/credentials, and no filtering or
account settings were changed. Production improvements require a later
reviewed release and observation; nothing was published during this audit.
