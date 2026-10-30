#!/usr/bin/env python3
"""Query OfficialConnect GA4 analytics without a browser.

Replaces the manual GA4 Realtime/exploration checks with the GA4 Data API:
- `section-timing`: per-section mean of duration_ms for sync_section
  events with sync_mode=refresh (the Task 2 exploration; median/max need
  the GA4 UI — the Data API client only aggregates TOTAL/COUNT).
- `event-check`: look for an event name (e.g. refresh_finished) in the
  last-30-min Realtime window (the Task 3/4 check).
- `sync-reliability`: distinct GA4-reported user counts for failed syncs,
  with rates over the observed login-start-or-failure population.

Auth: uses Application Default Credentials from an approved local sign-in or
credential flow with Viewer access to the GA4 property. Property id via
--property or GA4_PROPERTY_ID. Never store credential files in the repo.

Requires: python3 -m venv .venv; .venv/bin/pip install -r scripts/requirements-ga4.txt
Run: source .venv/bin/activate; python scripts/ga4_query.py ...
"""

import argparse
import os
import sys
from dataclasses import dataclass, field

PROPERTY_ENV = "GA4_PROPERTY_ID"


def _client():
    try:
        from google.analytics.data_v1beta import BetaAnalyticsDataClient
    except ImportError:
        sys.exit("Missing dependency: pip install google-analytics-data")
    try:
        return BetaAnalyticsDataClient()
    except Exception as exc:  # noqa: BLE001 - surface auth errors plainly
        sys.exit(f"Could not create GA4 client (check credentials): {exc}")


def _property(args) -> str:
    prop = args.property or os.environ.get(PROPERTY_ENV, "")
    if not prop:
        sys.exit(f"Set --property or {PROPERTY_ENV} to the GA4 numeric property id.")
    return f"properties/{prop}"


def cmd_section_timing(args) -> int:
    from google.analytics.data_v1beta.types import (
        DateRange,
        Dimension,
        Filter,
        FilterExpression,
        FilterExpressionList,
        Metric,
        MetricAggregation,
        RunReportRequest,
    )

    client = _client()
    request = RunReportRequest(
        property=_property(args),
        dimensions=[Dimension(name="customEvent:section")],
        metrics=[
            Metric(name="customEvent:duration_ms"),
            Metric(name="eventCount"),
        ],
        # TOTAL only (this API version lacks AVERAGE/MEDIAN); the
        # per-section mean is derived locally as total_ms / events.
        metric_aggregations=[MetricAggregation.TOTAL],
        dimension_filter=FilterExpression(
            and_group=FilterExpressionList(
                expressions=[
                    FilterExpression(
                        filter=Filter(
                            field_name="eventName",
                            string_filter={"value": "sync_section"},
                        )
                    ),
                    FilterExpression(
                        filter=Filter(
                            field_name="customEvent:sync_mode",
                            string_filter={"value": "refresh"},
                        )
                    ),
                ]
            )
        ),
        date_ranges=[DateRange(start_date=args.days_ago, end_date="today")],
    )
    try:
        response = client.run_report(request)
    except Exception as exc:  # noqa: BLE001
        sys.exit(f"Report request failed: {exc}")
    if not response.rows:
        print("No sync_section/refresh rows in range (definitions accrue from Sep 23, 2026).")
        return 0
    print(f"{'section':<24}{'avg_ms':>10}{'events':>8}{'total_ms':>10}")
    for row in response.rows:
        section = row.dimension_values[0].value
        # With TOTAL+COUNT aggregations each section yields one summary row
        # (RESERVED_*) plus its detail row; the detail row carries values.
        values = [v.value for v in row.metric_values]
        total = float(values[0]) if values[0] else 0.0
        count = int(float(values[1])) if len(values) > 1 and values[1] else 0
        avg = total / count if count else 0.0
        print(f"{section:<24}{avg:>10.1f}{count:>8}{total:>10.0f}")
    return 0


# 7-day per-section mean durations (ms), refresh syncs, measured 2026-10-02
# (KANBAN A4 re-measure; ~1900 events/section). A daily mean above 2x
# baseline is flagged; retune after major portal changes. These reflect the
# released code (broken seating/results waits inflate those two); re-measure
# again after the fast-refresh batch ships, when results/seating means
# should collapse toward their sub-second healthy latencies.
SECTION_BASELINES_MS = {
    "results": 21900,
    "seating": 16900,
    "marks": 9600,
    "attendance": 7000,
    "fees": 1800,
    "proctor": 1700,
    "timetable": 1400,
    "profile": 0,  # parse-only timing; excluded from checks
}

_SYNC_OK = {"ok", "complete", "success", "partial", "empty"}
_SYNC_BAD = {"error", "timeout", "session_expired", "network_error"}


@dataclass
class _QueryResult:
    users: int | None
    rows: list = field(default_factory=list)
    error: str | None = None
    incomplete: list[str] = field(default_factory=list)


def _ga4_types():
    """Load protobuf request types only for commands that need the SDK."""
    from google.analytics.data_v1beta import types
    return types


def _event_names_filter(types, names):
    expressions = [types.FilterExpression(filter=types.Filter(
        field_name="eventName", string_filter={"value": name}))
        for name in names]
    if len(expressions) == 1:
        return expressions[0]
    return types.FilterExpression(or_group=types.FilterExpressionList(
        expressions=expressions))


def _and_filters(types, *expressions):
    if len(expressions) == 1:
        return expressions[0]
    return types.FilterExpression(and_group=types.FilterExpressionList(
        expressions=list(expressions)))


def _or_filters(types, *expressions):
    if len(expressions) == 1:
        return expressions[0]
    return types.FilterExpression(or_group=types.FilterExpressionList(
        expressions=list(expressions)))


def _failure_filter(types, registered):
    """Failed sync/login outcomes plus legacy operation failures."""
    sync_outcomes = types.FilterExpression(filter=types.Filter(
        field_name="customEvent:outcome",
        in_list_filter={"values": [
            "error", "partial", "timeout", "network_error", "session_expired",
        ]}))
    login_outcomes = types.FilterExpression(filter=types.Filter(
        field_name="customEvent:outcome",
        in_list_filter={"values": [
            "error", "timeout", "network_error", "session_expired",
        ]}))
    # Keep event-specific outcome sets: partial is a sync result, while
    # login_flow_finished's cancelled outcome is intentionally excluded.
    event_specific = types.FilterExpression(or_group=types.FilterExpressionList(
        expressions=[
            _and_filters(types,
                _event_names_filter(types, ["sync_section", "sync_finished"]),
                sync_outcomes),
            _and_filters(types,
                _event_names_filter(types, ["login_flow_finished"]),
                login_outcomes),
            _event_names_filter(types, ["operation_failure"]),
        ]))
    exclusions = []
    for name in ("customEvent:failure_reason", "customEvent:reason"):
        if registered is not None and name in registered:
            exclusions.append(types.FilterExpression(not_expression=
                types.FilterExpression(filter=types.Filter(
                    field_name=name, string_filter={"value": "cancelled"}))))
    return _and_filters(types, event_specific, *exclusions)


def _request(types, prop, dimensions, start, end, dimension_filter):
    return types.RunReportRequest(
        property=prop,
        dimensions=[types.Dimension(name=name) for name in dimensions],
        metrics=[types.Metric(name="totalUsers")],
        date_ranges=[types.DateRange(start_date=start, end_date=end)],
        dimension_filter=dimension_filter,
        limit=100000,
    )


def _run_user_report(client, prop, dimensions, start, end, dimension_filter):
    """Fetch every page and retain GA4 completeness metadata."""
    types = _ga4_types()
    rows, incomplete, offset = [], [], 0
    try:
        while True:
            req = _request(types, prop, dimensions, start, end, dimension_filter)
            req.offset = offset
            response = client.run_report(req)
            rows.extend(response.rows)
            metadata = response.metadata
            if metadata and metadata.subject_to_thresholding:
                incomplete.append("GA4 thresholding applied")
            if metadata and metadata.data_loss_from_other_row:
                incomplete.append("GA4 grouped rows include an (other) loss bucket")
            if metadata and metadata.sampling_metadatas:
                incomplete.append("GA4 sampling applied")
            row_count = response.row_count
            if offset + len(response.rows) >= row_count:
                break
            if not response.rows:
                incomplete.append(
                    "GA4 returned an empty page before the reported row count was exhausted")
                break
            offset += len(response.rows)
        users = None
        if not dimensions:
            if rows and rows[0].metric_values:
                users = int(rows[0].metric_values[0].value or 0)
            else:
                users = 0
        return _QueryResult(users=users, rows=rows,
                            incomplete=sorted(set(incomplete)))
    except Exception as exc:  # noqa: BLE001 - report partial access explicitly
        return _QueryResult(users=None, rows=rows, error=str(exc),
                            incomplete=sorted(set(incomplete)))


def _registered_dimensions(client, prop):
    """Return registered event-scoped custom dimensions, or unknown on error."""
    from google.analytics.data_v1beta.types import GetMetadataRequest
    try:
        metadata = client.get_metadata(GetMetadataRequest(
            name=f"{prop}/metadata"))
        return {item.api_name for item in metadata.dimensions
                if item.custom_definition}
    except Exception:
        return None


def _cell(row, index):
    return row.dimension_values[index].value if index < len(row.dimension_values) else ""


def _print_query_status(label, result):
    if result.error:
        print(f"  {label}: unavailable ({result.error})")
    elif result.incomplete:
        print(f"  {label}: incomplete ({'; '.join(result.incomplete)})")


def cmd_sync_reliability(args) -> int:
    """Bounded distinct-user sync report; grouped rows intentionally overlap."""
    client, prop = _client(), _property(args)
    types = _ga4_types()
    registered = _registered_dimensions(client, prop)
    failure_filter = _failure_filter(types, registered)
    print("Sync reliability — affected users")
    print(f"Date range: {args.days_ago} through {args.end_date}")
    print("Measure: GA4-reported users (installation proxy), not physical unique phones.")
    print("No student reidentification; row user counts overlap and must not be summed.")

    starts_filter = _event_names_filter(types, ["login_flow_started"])
    starts = _run_user_report(client, prop, [], args.days_ago, args.end_date,
        starts_filter)
    failures = _run_user_report(client, prop, [], args.days_ago, args.end_date,
        failure_filter)
    population = _run_user_report(
        client, prop, [], args.days_ago, args.end_date,
        _or_filters(types, starts_filter, failure_filter))
    print(f"Login-start users: {starts.users if starts.users is not None else 'unavailable'}")
    print("Observed sync population (login starts or failed sync/login events): "
          f"{population.users if population.users is not None else 'unavailable'}")
    print(f"Users with failed sync/login event: {failures.users if failures.users is not None else 'unavailable'}")
    _print_query_status("login starts", starts)
    _print_query_status("observed sync population", population)
    _print_query_status("failure union", failures)
    can_rate = (population.users is not None and population.users > 0 and
                failures.users is not None and not population.error and
                not failures.incomplete and
                not population.incomplete and
                failures.users <= population.users)
    if can_rate:
        print("Affected-user rate: "
              f"{failures.users / population.users:.1%} of observed sync users")
    elif (population.users == 0 and not population.error and
          not population.incomplete):
        print("Affected-user rate: unavailable (no observed sync users in range)")
    elif (population.users is not None and failures.users is not None and
          failures.users > population.users):
        print("Affected-user rate: withheld (failure count exceeds observed population)")
    else:
        print("Affected-user rate: withheld (query failed or GA4 data may be incomplete)")

    dimensions = [
        ("failure reason", "customEvent:failure_reason"),
        ("failure outcome", "customEvent:outcome"),
        ("failure stage", "customEvent:stage"),
        ("legacy operation_failure reason", "customEvent:reason"),
        ("section", "customEvent:section"),
        ("processing step", "customEvent:failure_step"),
        ("exception kind", "customEvent:exception_kind"),
        ("cached data", "customEvent:has_cached_data"),
        ("app version", "customEvent:app_version"),
        ("device model", "deviceModel"),
        ("operating system", "operatingSystemWithVersion"),
    ]
    available = []
    for label, name in dimensions:
        custom = name.startswith("customEvent:")
        if custom and registered is not None and name not in registered:
            print(f"Breakdown {label}: unavailable (GA4 custom dimension not registered)")
            continue
        if custom and registered is None and name == "customEvent:reason":
            print("Breakdown legacy operation_failure reason: unavailable (could not verify registration)")
            continue
        available.append((label, name))
    for label, dimension in available:
        # Apply the event filter to each query. GA4 totalUsers in each grouped
        # row is distinct for that bucket, but users can occur in many rows.
        breakdown_filter = failure_filter
        if dimension == "customEvent:reason":
            breakdown_filter = _and_filters(types, failure_filter,
                _event_names_filter(types, ["operation_failure"]))
        result = _run_user_report(client, prop, [dimension], args.days_ago,
                                  args.end_date, breakdown_filter)
        if result.error:
            print(f"Breakdown {label}: unavailable ({result.error})")
            continue
        print(f"Breakdown {label} (distinct users per bucket; overlapping):")
        for row in result.rows:
            value = _cell(row, 0) or "(unset)"
            users = int(row.metric_values[0].value or 0)
            rate = (
                f"; {users / population.users:.1%} of observed sync users"
                if can_rate and not result.incomplete and
                users <= population.users
                else ""
            )
            print(f"  {value}: {users}{rate}")
        _print_query_status(label, result)
    if registered is None:
        print("Custom-dimension registration metadata unavailable; missing-dimension errors are reported per breakdown.")
        print("Cancellation exclusion could not be verified; failure counts may include intentional cancellations.")
    return 0 if (population.users is not None and failures.users is not None) else 2


def _run(client, prop, dimensions, metrics, date, extra_filter=None):
    from google.analytics.data_v1beta.types import (
        DateRange,
        Dimension,
        Metric,
        RunReportRequest,
    )

    req = RunReportRequest(
        property=prop,
        dimensions=[Dimension(name=d) for d in dimensions],
        metrics=[Metric(name=m) for m in metrics],
        date_ranges=[DateRange(start_date=date, end_date=date)],
    )
    if extra_filter is not None:
        req.dimension_filter = extra_filter
    try:
        return client.run_report(req), None
    except Exception as exc:  # noqa: BLE001
        return None, str(exc)


def _event_filter(event_names):
    from google.analytics.data_v1beta.types import Filter, FilterExpression

    return FilterExpression(
        filter=Filter(
            field_name="eventName",
            in_list_filter={"values": list(event_names)},
        )
    )


def cmd_daily_health(args) -> int:
    """One lightweight daily quality gate over yesterday's events (~3 calls)."""
    client = _client()
    prop = _property(args)
    day = args.date
    verdicts = []  # (level, message); level in OK/WARN/FAIL

    def outcome_breakdown(event):
        resp, err = _run(
            client, prop,
            ["customEvent:outcome"], ["eventCount"], day,
            _event_filter([event]),
        )
        if err:
            return None, err
        return {r.dimension_values[0].value: int(r.metric_values[0].value)
                for r in resp.rows}, None

    # 1. Sync outcome mix.
    sync, err = outcome_breakdown("sync_finished")
    if err:
        verdicts.append(("FAIL", f"sync_finished unreadable: {err}"))
    elif not sync:
        verdicts.append(("WARN", "sync_finished: no events yesterday"))
    else:
        total = sum(sync.values())
        bad = sum(v for k, v in sync.items() if k in _SYNC_BAD)
        rate = bad / total if total else 0.0
        detail = ", ".join(f"{k}={v}" for k, v in sorted(sync.items()))
        if rate >= 0.15:
            verdicts.append(("FAIL", f"sync error rate {rate:.0%} ({detail})"))
        elif rate >= 0.05:
            verdicts.append(("WARN", f"sync error rate {rate:.0%} ({detail})"))
        else:
            verdicts.append(("OK", f"sync error rate {rate:.0%} ({detail})"))

    # 2. Top failure reasons across sync + operational failures.
    from google.analytics.data_v1beta.types import (
        Dimension as _Dim, Metric as _Met, DateRange as _DR,
        RunReportRequest as _RR,
    )
    try:
        resp = client.run_report(_RR(
            property=prop,
            dimensions=[_Dim(name="customEvent:failure_reason")],
            metrics=[_Met(name="eventCount")],
            date_ranges=[_DR(start_date=day, end_date=day)],
            dimension_filter=_event_filter(
                ["sync_section", "sync_finished", "operation_failure"]),
        ))
        reasons = sorted(
            ((r.dimension_values[0].value or "(none)",
              int(r.metric_values[0].value)) for r in resp.rows),
            key=lambda kv: -kv[1],
        )[:3]
        if reasons:
            verdicts.append(("OK", "top failure reasons: " + ", ".join(
                f"{k}={v}" for k, v in reasons)))
    except Exception as exc:  # noqa: BLE001
        verdicts.append(("WARN", f"failure reasons unreadable: {exc}"))

    # 3. Section durations vs baseline (yesterday's mean per section).
    resp, err = _run(
        client, prop,
        ["customEvent:section"],
        ["customEvent:duration_ms", "eventCount"], day,
        _event_filter(["sync_section"]),
    )
    if err:
        verdicts.append(("FAIL", f"section timing unreadable: {err}"))
    else:
        for r in resp.rows:
            section = r.dimension_values[0].value
            base = SECTION_BASELINES_MS.get(section)
            if not base:
                continue
            total = float(r.metric_values[0].value or 0)
            count = int(float(r.metric_values[1].value or 0))
            mean = total / count if count else 0.0
            if mean > 2 * base:
                verdicts.append((
                    "WARN",
                    f"{section} mean {mean:.0f}ms > 2x baseline {base}ms"))
        verdicts.append(("OK", "section durations within 2x baseline"))

    # 4. Login completion.
    login, err = outcome_breakdown("login_flow_finished")
    if err:
        verdicts.append(("FAIL", f"login outcomes unreadable: {err}"))
    elif login:
        total = sum(login.values())
        good = sum(v for k, v in login.items() if k in _SYNC_OK)
        rate = good / total if total else 0.0
        detail = ", ".join(f"{k}={v}" for k, v in sorted(login.items()))
        if rate < 0.90:
            verdicts.append(("WARN", f"login success {rate:.0%} ({detail})"))
        else:
            verdicts.append(("OK", f"login success {rate:.0%} ({detail})"))

    # 5. Version adoption among syncing users (info only; unenriched
    # events such as raw screen views carry no app_version).
    resp, err = _run(
        client, prop, ["customEvent:app_version"], ["eventCount"], day,
        _event_filter(["sync_finished"]))
    if not err and resp.rows:
        mix = {r.dimension_values[0].value: int(r.metric_values[0].value)
               for r in resp.rows}
        total = sum(mix.values()) or 1
        top = sorted(mix.items(), key=lambda kv: -kv[1])[:3]
        if len(mix) == 1 and next(iter(mix)) == "":
            # app_version only ships from 1.1.5 onward; a fully blank mix
            # means the base is still on older clients.
            verdicts.append(("OK", "version mix: pre-1.1.5 clients (no data)"))
        else:
            verdicts.append(("OK", "version mix: " + ", ".join(
                f"{k or '(unset)'}={v / total:.0%}" for k, v in top)))

    levels = [level for level, _ in verdicts]
    for level, message in verdicts:
        print(f"[{level}] {message}")
    if "FAIL" in levels:
        return 2
    if "WARN" in levels:
        return 1
    return 0


def cmd_event_check(args) -> int:
    from google.analytics.data_v1beta.types import (
        Dimension,
        Filter,
        FilterExpression,
        Metric,
        RunRealtimeReportRequest,
    )

    client = _client()
    request = RunRealtimeReportRequest(
        property=_property(args),
        dimensions=[Dimension(name="eventName")],
        metrics=[Metric(name="eventCount")],
        dimension_filter=FilterExpression(
            filter=Filter(
                field_name="eventName",
                string_filter={"value": args.name},
            )
        ),
    )
    try:
        response = client.run_realtime_report(request)
    except Exception as exc:  # noqa: BLE001
        sys.exit(f"Realtime request failed: {exc}")
    total = sum(int(r.metric_values[0].value) for r in response.rows)
    if total:
        print(f"FOUND: {args.name} x{total} in the Realtime window.")
        return 0
    print(f"ABSENT: {args.name} not in the Realtime window (verified negative).")
    return 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--property", default="", help="GA4 numeric property id")
    sub = parser.add_subparsers(dest="cmd", required=True)

    timing = sub.add_parser("section-timing", help="per-section refresh durations")
    timing.add_argument("--days-ago", default="28daysAgo")
    timing.set_defaults(func=cmd_section_timing)

    check = sub.add_parser("event-check", help="Realtime presence of one event")
    check.add_argument("--name", default="refresh_finished")
    check.set_defaults(func=cmd_event_check)

    health = sub.add_parser("daily-health", help="lightweight daily quality gate")
    health.add_argument("--date", default="yesterday")
    health.set_defaults(func=cmd_daily_health)

    reliability = sub.add_parser(
        "sync-reliability", help="distinct affected-user sync report")
    reliability.add_argument("--days-ago", default="28daysAgo")
    reliability.add_argument("--end-date", default="yesterday")
    reliability.set_defaults(func=cmd_sync_reliability)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
