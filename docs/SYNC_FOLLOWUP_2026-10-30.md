# Sync follow-up — 30 October 2026

## Live analytics checked

Read the signed-in GA4 event reports for property 461868611, 2–29 October
2026 (28 complete days). The UI rounds these values; they are not exact API
exports and must not be used for precise percentages.

| Event / outcome or reason | Events | GA4 total users |
|---|---:|---:|
| `sync_section`, all | 199K | 3.6K |
| section outcome `ok` | 164K | 3.6K |
| section outcome `empty` | 21K | 3.3K |
| section outcome `error` | 11K | 2.1K |
| section outcome `partial` | 3.8K | 1.3K |
| section reason `content_not_ready` | 12K | 2.1K |
| section reason `missing_fields` | 2.2K | 891 |
| section reason `invalid_content` | 503 | 81 |
| section reason `timeout` | 331 | 198 |
| section reason `missing_links` | 297 | 69 |
| `login_flow_finished`, all | 75K | 4.4K |
| login outcome `success` | 25K | 3.6K |
| login outcome `timeout` | 11K | 2.8K |
| login outcome `error` | 1.5K | 894 |
| login outcome `cancelled` | 39K | 3.9K |

Users overlap across outcomes, reasons, versions, and sections. Do not add the
user rows. An empty section can be legitimate; it is not automatically an
error. A user can time out on one attempt and succeed later. Cancellation is
not proof of a crash or a user deliberately abandoning the app.

The timeout population is much larger at the full-flow level than at the
section level. Reporting only `sync_section` would miss stalled sign-ins and
flows that never start scraping. The reliability report must include terminal
login failures and distinguish its observed population from all installed
devices. GA4-reported users are an installation proxy, not a physical-device
census. Consent and collection gaps remain.

For `sync_section`, version 1.1.7+16 accounts for 181K events / 3.5K users;
1.1.5+14 accounts for 18K / 890 users. These version groups overlap as users
update. They show adoption among observed syncing users, not Play delivery to
every eligible device.

## Live website and Android attempt

The website initially returned HTTP 200. A native emulator sign-in using the
authorized test account reached the signing-in stage at approximately 6.7–8.2
seconds, but did not complete. The existing 75-second deadline displayed the
connection error. Later, both Chrome and a direct HTTPS check received a
connection refusal. A successful login and complete scrape duration therefore
remain unverified; do not publish a successful timing from this attempt.

After rebuilding and installing the connection fix, the same native Android
flow showed the connection error within the first 5.9-second observation
window. This verifies the native main-frame failure path on this emulator;
it is an upper observation bound, not a precise login latency. The saved
native form restored its input values after relaunch. A credential-free error
capture is kept under ignored `build/ui-smoke/connection-unavailable-oct30.png`.

No credentials, cookies, student records, or account screenshots belong in this
report or test fixtures. Only the named Android emulator was used; there was
no physical Samsung A52s, tablet, or television test.

## Changes and release gate

- The initial website navigation receives a separate 15-second connection
  deadline; a native main-frame failure can end it sooner. WebView startup and
  session clearing retain the overall cap rather than consuming that short
  connection window. Valid portal redirects cancel the initial deadline.
- Login/scrape still has a 75-second overall cap. Timeout removes the browser
  and preserves existing cached information.
- New operational failures retain `reason` and also emit `failure_reason`, so
  shared reports can group them without silently losing the older parameter.
- The CLI reports distinct affected users, with server-deduplicated totals,
  overlapping breakdowns, historical parameter limitations, and incomplete-data
  warnings. It needs approved Application Default Credentials; the current
  local API check has none. Browser access works independently.
- Independent review identified redirect false failures, connection timing
  before navigation, recoverable-error terminal outcomes, and an invalid
  denominator assumption. Apply the review patches and rerun tests before
  staging a release.

Only eight custom dimensions were registered initially: `app_version`,
`duration_bucket`, `failure_reason`, `outcome`, `platform`, `release_cohort`,
`section`, and `sync_mode`. Analytics briefly became unreachable during the
first save attempt. Once access recovered, the following five event-scoped
definitions were created and verified in the list (13 total): `reason`,
`stage`, `failure_step`, `exception_kind`, and `has_cached_data`.
Their values are bounded categories or a zero/one cache-availability flag;
no student identifiers, exception messages, URLs, or flow IDs were registered.
New definitions do not backfill historical reports. A screenshot is under
ignored `build/ui-smoke/ga4-diagnostic-definitions-oct30.jpg`.
Approved local API credentials are still absent.

## Final verification

- Full Flutter suite: 182 tests passed, including 12 focused login deadline,
  redirect, HTTP error, lifecycle, late callback, and recovery regressions.
- Phone integration: three tests passed on the Android emulator at 412×915.
- Tablet integration: three tests passed on the same emulator at 800×1280.
  Both runs exercised real preference storage, usable navigation during an
  update, cache preservation/restart, and repeated native WebView disposal.
- Flutter analysis: no issues found. Python reporting and packaging suite:
  26 tests passed. Whitespace validation passed.
- The final independent review found no further actionable issues in the
  revised login deadline and HTTP-error handling.
- A normal debug APK was rebuilt after the integration runs, to avoid leaving
  the instrumented test application installed as the user-facing demo.
- The final normal debug APK was installed and opened on the phone emulator.
  The release APK also rebuilt successfully (74.6 MB). It retains the current
  1.1.7+16 version for local preflight only; it is not an upload-ready new
  version. Confirm the highest Play version code and assign a fresh release
  version before creating a submission.
- Final release artifact checks passed: required native libraries in all three
  packaged ABIs, 16 KB ELF page alignment, APK ZIP alignment, and static
  Android release configuration.

Release is not published by this follow-up. A successful authenticated live
scrape remains a release confidence gap while the website is unavailable.
