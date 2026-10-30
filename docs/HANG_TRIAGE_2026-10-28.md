# Hang report investigation — 2026-10-28

Report supplied by the maintainer: “app hangs now more, then before.” Device,
installed version, affected screen and reproduction steps are not yet known.

## Reproduced defect

`SisData.setup()` awaited native telemetry preference acknowledgements before
decoding saved academic data. An unresponsive collection-toggle call therefore
prevented restoration of attendance and marks. This await is also present in
the upstream main revision checked during this investigation (`2607528`).

The new offline regression test holds the telemetry acknowledgement pending
and asserts that the cached academic sections are still usable. It failed
before the patch (attendance remained empty) and passed after the patch.

The patch applies the preference asynchronously, with an error handler, so
academic-cache restoration does not wait for native telemetry. The existing
consent path updates its in-memory enabled flag before awaiting the native
acknowledgement; this change does not enable collection after an opt-out.

This is a confirmed startup-stall mechanism, not proof of this reporter's cause
or a measurement of its prevalence. It does not establish that scrolling or
native Android ANRs have the same cause.

## Live evidence limits

- GA4 Data API query failed because Application Default Credentials were not
  configured for this shell.
- Firebase Crashlytics showed “This app does not exist or you do not have
  permission to view it” for the currently signed-in browser account.
- No current crash/ANR rates, affected-device counts, or release adoption
  figures were obtained. Prior measurements must not be presented as current.
- No Fire TV interactions were performed in this investigation.

## Follow-up

Obtain the reporter's installed version, phone model and screen/action where
the hang occurs. With reporting access restored, compare affected users by
app version, inspect ANR stacks and slow startup traces, and distinguish
unresponsive UI from a long sign-in/update wait. Validate a release build on
an explicitly selected phone emulator/device before publishing this patch.

The fix remains local; no build has been uploaded or published by this task.
