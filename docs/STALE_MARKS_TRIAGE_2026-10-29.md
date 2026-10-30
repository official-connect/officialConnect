# Stale marks and background refresh

Report: Results shows marks for only some courses while refresh repeatedly fails.
The screenshot establishes stale or incomplete displayed data and a failed
refresh; it does not establish the underlying session, network or parser failure.

## Confirmed local findings and fixes

- Marks were committed only when the entire scrape returned. A later course or
  optional section could exceed the login/refresh budget and discard newly read
  marks. The scraper now publishes independent marks checkpoints after each
  successfully parsed course; background refresh merges each checkpoint into
  the existing academic cache. Unrefreshed courses stay visible. This follows
  the existing attendance checkpoint behavior and applies to an existing account.
- The retry-needed checks included attendance, timetable and seating, but omitted
  marks. Failed, partial or pending marks now keep updates eligible for retry,
  including after restoring the cache on restart. Existing scheduling and
  throttling still apply; this does not introduce an immediate retry loop.

## Review and validation

CodeRabbit-style manual review checked partial-cache merging, account gating,
callback failure propagation, snapshot independence and cancellation. The review
caught and fixed the corresponding omission in startup's retry check. Cache
callback errors propagate rather than being counted as course parsing failures.

- Full Flutter suite: 158 tests pass.
- Analyzer: no issues.
- Regressions cover marks delivered before cancellation, independent per-course
  snapshots, retained cache on marks failure, and retry eligibility after restart.
- The restart assertion was added after the full run; the focused offline suite
  was run again for that addition.

## Limits

No credentials or telemetry identify this reporter's failed request. This does
not establish that every missing mark in their account is a scrape failure, and
does not guarantee completion while the service is unavailable or login requires
attention. Existing navigation/session failure handling and time budgets remain.
The background-fetch probe can still run before course parsing/checkpointing.
No live analytics were retrieved, no physical devices were touched, and no build
was published in this investigation. Changes are local and unreleased.
