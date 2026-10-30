# Student feedback issues — 25 Oct 2026

Roadmap: https://github.com/official-connect/officialConnect/issues/44

- [Fix page reset on phone/tablet resize and timetable overflow at large text sizes](https://github.com/official-connect/officialConnect/issues/32)
- [Prevent animated tab transitions from inflating feature-usage analytics](https://github.com/official-connect/officialConnect/issues/33)
- [Investigate reported stale data, blank CIE marks and login/date-picker failures](https://github.com/official-connect/officialConnect/issues/34)
- [Make Attendance and CIE charts easier to understand and explore](https://github.com/official-connect/officialConnect/issues/35)
- [Add an attendance planner for 75% and 85% targets](https://github.com/official-connect/officialConnect/issues/36)
- [Add an SGPA/CGPA and target-grade planner](https://github.com/official-connect/officialConnect/issues/37)
- [Improve timetable planning with holidays and a clearer Today overview](https://github.com/official-connect/officialConnect/issues/38)
- [Add a curated campus notices and events board in Explore](https://github.com/official-connect/officialConnect/issues/39)
- [Triage theme, profile-photo, menu and fee-link regressions from student feedback](https://github.com/official-connect/officialConnect/issues/40)
- [Clarify developer identity, affiliation and privacy information in About](https://github.com/official-connect/officialConnect/issues/41)
- [Add a gentle, dismissible reminder to complete the feedback form](https://github.com/official-connect/officialConnect/issues/42)
- [Add a considerate Play Store rating prompt after successful app use](https://github.com/official-connect/officialConnect/issues/43)

The source is the maintainer-provided survey summary. Historical feedback is marked for current-release verification; locally reproduced review defects are identified separately in their issue bodies. No account credentials or private screenshots were uploaded.

The temporary review probe was preserved at `/tmp/officialconnect-ui-review-probe-2026-10-25.dart` and removed from the active test suite after documenting the failures in issues #32 and #33. Full existing test suite before the probes: 140 passing tests. The extra probes reproduced three unresolved defects; no product fixes were made during issue triage.
