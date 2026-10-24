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

Use this report to answer questions such as “what percentage of syncing
devices experienced a timeout?” without identifying a student.

1. In GA4 Admin → Custom definitions, create the event-scoped dimensions
   `failure_reason`, `section`, `sync_mode`, and `app_version` if they are
   not already present. These are bounded app-generated labels; do not add
   USN, names, portal URLs, or free-text parameters.
2. In Explore, create a Free form report for the last 28 days with
   **Active users** as the metric and `failure_reason` as the row.
3. Filter to `sync_section` where `outcome` is `error` or `partial`, then
   repeat for `operation_failure` to cover top-level or cache interruptions.
4. Use **Active users with `sync_finished`** in the same period as the
   denominator. For each reason: affected-device rate = distinct affected
   users / distinct syncing users. A device can appear in more than one
   reason, so bucket percentages are intentionally not expected to sum to
   100%.
5. Save the report as **Sync reliability — affected devices** and compare it
   by `app_version` before and after each release.

Current approved failure buckets are: `session_expired`, `timeout`,
`network_error`, `browser_not_ready`, `content_not_ready`, `parse_error`,
`missing_links`, `invalid_content`, `empty_response`, `request_error`,
`cache_write`, `cancelled`, and `unknown`. `unknown` is a follow-up signal:
it must be investigated and replaced by a bounded reason, never by logging
raw exception text or student data.

## Future automation (not yet built)

- `daily-health` already runs the numbers; a weekly rollup mode plus a cron
  job can email/notify a digest (adoption, error rate, slowest sections,
  top crashes) so humans only open consoles on WARN/FAIL weeks.
- The digest must use the service account, never a human's login.
