# Analytics Access Runbook (GA4 + Firebase)

Goal: anyone's analytics access never depends on one person. Two co-admins
can grant read access to new contributors; leavers get removed the same way.

## Role design

| Role | Who | Can do |
|---|---|---|
| Administrator (GA4 property) | You + 2 trusted students | Grant/revoke any role, manage data settings |
| Viewer (GA4 property) | Every other contributor | Read all reports and explorations |
| Analyst (GA4 property) | Contributors on the analytics track | Viewer + create/share explorations |
| Firebase Viewer (GCP IAM) | Contributors needing Crashlytics | Read crashes and performance data |

Nobody outside co-admins gets Editor/Marketer. The service-account key
(`ga4-key.json`) stays with automation only — humans use their own Google
accounts, never the key.

## Granting read access (any co-admin can do this)

GA4 reporting access:
1. GA4 → Admin → **Property access management** (unofficialconnect property).
2. **Add users** → contributor's Google email → role **Viewer** (or
   **Analyst** for analytics-track contributors) → Add.

Crashlytics/Performance access:
1. Google Cloud Console → IAM & Admin → **IAM** (project behind the app).
2. **Grant access** → contributor's email → role **Firebase Viewer** → Save.

Tell the contributor both grants exist; most only need the GA4 one.

## Promoting a co-admin

Only an existing Administrator does this, and only after the contributor has
merged analytics work for ~2 months:
1. Same Property access management screen → new co-admin → **Administrator**.
2. Record the change (date + who approved) in the team notes.

Never have fewer than 2 or more than 3 Administrators.

## Offboarding (graduation / stepping away)

1. GA4 Property access management → remove the person.
2. GCP IAM → remove the person.
3. If they ever held the service-account key (they shouldn't), rotate it:
   Cloud Console → Service Accounts → create new key, update automation,
   delete the old key.

Do this the week they leave, not "later".

## Quarterly access review (15 minutes, any co-admin)

1. Export the member lists from both screens above.
2. Remove anyone who hasn't contributed in 6 months.
3. Confirm the Administrator count is 2–3.

## Sync reliability report (monthly, 10 minutes)

The bounded CLI report uses GA4's `totalUsers` metric, which deduplicates the
users returned by each server-side event filter. Its denominator is the
distinct-user union of `login_flow_started` and users with failed sync or login
events in the exact same date range. This observable population includes
terminal login failures even when no sync or login-start event was recorded;
it is not a claim that every counted user completed a login attempt.

```sh
.venv/bin/python scripts/ga4_query.py sync-reliability \
  --days-ago 28daysAgo --end-date yesterday
```

The failure union includes `sync_section` and `sync_finished` with outcome
`error`, `partial`, `timeout`, `network_error`, or `session_expired`,
`login_flow_finished` with `error`, `timeout`, `network_error`, or
`session_expired`, plus `operation_failure` (whose historical event name
itself denotes failure). Login `cancelled` outcomes are excluded. Intentional
`cancelled` reasons are excluded when the matching custom dimension is
registered and discoverable. If registration metadata cannot be read, the
report says cancellation exclusion is unverified.
Historical `operation_failure` used the parameter `reason`; newer events may
use `failure_reason`. The CLI uses `reason` only when GA4 metadata confirms
that custom dimension is registered, and limits that breakdown to
`operation_failure`. Old event data cannot be retroactively renamed.

Optional breakdowns include failure outcome, reason, stage, section, processing
step, exception kind, cached-data availability, app version, device model, and
operating system. Outcome breakdown is especially useful for terminal login
failures, which may not have a `failure_reason`. Register event-scoped custom
dimensions for `outcome`, `failure_reason`, `stage`, `section`, `failure_step`,
`exception_kind`, `has_cached_data`, `app_version`, and `reason` (only if
historical `operation_failure` analysis is needed). Do not register identifiers
or free-text fields. A missing definition or failed query is shown as
unavailable; it must not be read as zero failures. GA4 may apply
thresholding or row loss; the report marks affected results incomplete and
withholds the overall rate when the numerator or denominator is incomplete.
Grouped rows are distinct-user counts per bucket and can overlap. Never add
those rows to calculate the failure union. The failure union and observed
population are separate dimension-free server queries. Each displayed bucket
rate uses the same observed-population denominator.

These are **GA4-reported users (an installation proxy)**, not verified
physical unique phones. GA4 user identity can differ from device identity, and
this report does not reidentify students. Treat the values as an aggregate
reliability signal, not a person/device census. `login_flow_started` is an
attempt count reported separately from the observed-population denominator. If
GA4 retention, consent, or collection gaps affect either query, report the
limitation rather than extrapolating.

The command needs Application Default Credentials from an account with GA4
Viewer access and a numeric property ID supplied with `--property` or
`GA4_PROPERTY_ID`. For local setup, install `scripts/requirements-ga4.txt`,
then authenticate through the approved organization flow and select the
property. Do not create or copy service-account keys into this repository.
If ADC is absent, the command reports the access error; no analytics data is
returned. Custom-dimension definitions can take time to populate and do not
backfill historical events.

Current approved failure buckets are: `session_expired`, `timeout`,
`network_error`, `browser_not_ready`, `content_not_ready`, `parse_error`,
`missing_links`, `invalid_content`, `empty_response`, `request_error`,
`cache_write`, `cancelled`, and `unknown`. `unknown` is a follow-up signal:
it must be investigated and replaced by a bounded reason, never by logging
raw exception text or student data.

## Future automation (not yet built)

- `daily-health` remains an event-count diagnostic and is not an affected-user
  rate. A scheduled rollup could summarize both command outputs separately.
- The digest must use the service account, never a human's login.
