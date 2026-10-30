# Sync failure investigation — 29 October 2026

## Observed production evidence

Firebase Crashlytics was accessible. For 23–29 October, it reported approximately
5.1K nonfatal events affecting 1.6K users, five crashes affecting one user, and
four ANRs affecting four users. Counts overlap and are not installation-level
failure percentages.

The operational issue group's heading suggested cache writes, but its variants
showed a different distribution: roughly 2.4K events / 1.4K users belonged to the
scraping/unknown variant; only 26 events / 11 users belonged to the cache-write
variant. A separate photo HTTP 403 issue had about 2.7K events / 387 users.
These are observations, not proof that every affected sync lost all data.

GA4 could not be queried in this environment: its dashboard hostname was blocked
by the current network resolver and the local query script lacked application
default credentials. No network settings were changed.

## Changes prepared locally

- Add bounded exception category, section, processing step, duration, and cache
  availability to sync failure events. Never include credentials, document HTML,
  raw exception text, or student identifiers in those fields.
- Keep recoverable failures in analytics and breadcrumbs rather than creating
  synthetic crash reports.
- Quarantine malformed sections so usable cached data and other successful
  sections survive. Preserve partial attendance/marks checkpoints.
- Keep caches isolated between accounts, including the demonstration account.
- Start the overall deadline before native browser initialization. On an
  interactive timeout, show a clear message and a way back to sign-in instead of
  silently returning. Background timeouts complete once and preserve cache.
- Attribute full-payload cache failures to an unknown section rather than the
  last section scraped; attribute individual checkpoints to their section.

## Review and validation

Independent review identified cache section misattribution and a legacy empty
proctor-list compatibility issue; both were patched with regression coverage.
Tests cover failure classification and privacy bounds, partial cache preservation,
restart restoration, account isolation, scraper progress, and both timeout modes.
Final validation: all 171 Flutter tests passed, Flutter analysis reported no
issues, the Android debug APK built successfully, and `git diff --check` passed.
An emulator login attempt reached the new explicit timeout screen when the
portal remained unavailable.

The Android emulator was used explicitly; no physical or television device was
used. Live portal access timed out from this environment, so a successful
authenticated scrape and the historical root cause of the unknown events remain
unverified. Previously authorized test credentials stay out of this report and
fixtures. These changes have not been published.

## After deployment

Compare distinct affected installations with distinct sync-attempt installations,
split by release, failure reason, section and processing step. Event counts alone
cannot provide the requested device percentages. Confirm event delivery and
dimension registration in GA4 before claiming dashboard coverage. Investigate
photo 403 separately; it is not evidence of a failed academic-data sync.
