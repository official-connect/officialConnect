"""Request and aggregation coverage for the bounded GA4 reliability report."""

import contextlib
import io
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ga4_query

try:
    from google.analytics.data_v1beta import types
except ImportError:  # Pure aggregation and CLI tests still run without the SDK.
    types = None


def _response(users, *, rows=None, row_count=None, threshold=False, row_loss=False,
              sampled=False):
    metric_value = lambda value: SimpleNamespace(value=str(value))
    return SimpleNamespace(
        rows=rows if rows is not None else [SimpleNamespace(
            dimension_values=[], metric_values=[metric_value(users)])],
        row_count=row_count if row_count is not None else (len(rows) if rows is not None else 1),
        metadata=SimpleNamespace(subject_to_thresholding=threshold,
                                 data_loss_from_other_row=row_loss,
                                 sampling_metadatas=(
                                     [SimpleNamespace(samples_read_count=1,
                                                      sampling_space_size=2)]
                                     if sampled else [])),
    )


@unittest.skipIf(types is None, "google-analytics-data SDK is not installed")
class GA4RequestTests(unittest.TestCase):
    def test_unsegmented_union_request_uses_distinct_users_and_bounded_dates(self):
        request = ga4_query._request(
            types, "properties/123", [], "28daysAgo", "yesterday",
            ga4_query._event_names_filter(types, ["login_flow_started"]))
        self.assertEqual(request.property, "properties/123")
        self.assertEqual([d.name for d in request.dimensions], [])
        self.assertEqual([m.name for m in request.metrics], ["totalUsers"])
        self.assertEqual(request.date_ranges[0].start_date, "28daysAgo")
        self.assertEqual(request.date_ranges[0].end_date, "yesterday")
        self.assertEqual(request.limit, 100000)

    def test_observed_population_filter_unions_starts_and_failure_events(self):
        starts = ga4_query._event_names_filter(types, ["login_flow_started"])
        failures = ga4_query._failure_filter(types, None)
        population = ga4_query._or_filters(types, starts, failures)
        wire = str(population)
        self.assertIn("login_flow_started", wire)
        self.assertIn("operation_failure", wire)
        self.assertIn("sync_finished", wire)
        self.assertIn("login_flow_finished", wire)
        self.assertIn("timeout", wire)

    def test_failure_request_filters_failed_outcomes_and_registered_cancel_reasons(self):
        expr = ga4_query._failure_filter(types, {
            "customEvent:failure_reason", "customEvent:reason"})
        wire = str(expr)
        self.assertIn("sync_section", wire)
        self.assertIn("sync_finished", wire)
        self.assertIn("operation_failure", wire)
        self.assertIn("error", wire)
        self.assertIn("partial", wire)
        self.assertIn("timeout", wire)
        self.assertIn("network_error", wire)
        self.assertIn("session_expired", wire)
        self.assertIn("cancelled", wire)
        def find_login_branch(node):
            if node._pb.WhichOneof("expr") == "and_group":
                children = node.and_group.expressions
                if any(child._pb.WhichOneof("expr") == "filter" and
                       child.filter.field_name == "eventName" and
                       child.filter.string_filter.value == "login_flow_finished"
                       for child in children):
                    return node
                for child in children:
                    found = find_login_branch(child)
                    if found is not None:
                        return found
            elif node._pb.WhichOneof("expr") == "or_group":
                for child in node.or_group.expressions:
                    found = find_login_branch(child)
                    if found is not None:
                        return found
            return None

        login_branch = find_login_branch(expr)
        self.assertIsNotNone(login_branch)
        def find_outcome_filter(node):
            expression_type = node._pb.WhichOneof("expr")
            if expression_type == "filter" and node.filter.field_name == "customEvent:outcome":
                return set(node.filter.in_list_filter.values)
            if expression_type == "and_group":
                children = node.and_group.expressions
            elif expression_type == "or_group":
                children = node.or_group.expressions
            else:
                return None
            for child in children:
                found = find_outcome_filter(child)
                if found is not None:
                    return found
            return None

        login_outcomes = find_outcome_filter(login_branch)
        self.assertEqual(login_outcomes,
                         {"error", "timeout", "network_error", "session_expired"})
        # Legacy reason is only included in cancellation filtering when known.
        legacy_unknown = str(ga4_query._failure_filter(types, set()))
        self.assertNotIn("customEvent:reason", legacy_unknown)

    def test_pagination_accumulates_rows_and_marks_thresholding(self):
        row = lambda name, n: SimpleNamespace(
            dimension_values=[SimpleNamespace(value=name)],
            metric_values=[SimpleNamespace(value=str(n))])

        class Client:
            requests = []

            def run_report(self, request):
                self.requests.append(request)
                if request.offset == 0:
                    return _response(0, rows=[row("timeout", 3)], row_count=2,
                                     threshold=True)
                return _response(0, rows=[row("network_error", 2)], row_count=2)

        client = Client()
        result = ga4_query._run_user_report(
            client, "properties/123", ["customEvent:failure_reason"],
            "28daysAgo", "yesterday", ga4_query._event_names_filter(
                types, ["sync_finished"]))
        self.assertEqual([ga4_query._cell(r, 0) for r in result.rows],
                         ["timeout", "network_error"])
        self.assertEqual([r.offset for r in client.requests], [0, 1])
        self.assertIn("GA4 thresholding applied", result.incomplete)
        self.assertIsNone(result.users)  # Bucket rows are never summed as a union.

    def test_empty_page_before_row_count_is_marked_incomplete(self):
        client = mock.Mock()
        client.run_report.return_value = _response(
            0, rows=[], row_count=1)
        result = ga4_query._run_user_report(
            client, "properties/123", ["customEvent:failure_reason"],
            "28daysAgo", "yesterday", None)
        self.assertIsNone(result.users)
        self.assertTrue(any("empty page" in item for item in result.incomplete))

    def test_sampling_metadata_marks_dimensionless_count_incomplete(self):
        client = mock.Mock()
        client.run_report.return_value = _response(7, sampled=True)
        result = ga4_query._run_user_report(
            client, "properties/123", [], "28daysAgo", "yesterday", None)
        self.assertEqual(result.users, 7)
        self.assertIn("GA4 sampling applied", result.incomplete)


@unittest.skipIf(types is None, "google-analytics-data SDK is not installed")
class GA4AggregationTests(unittest.TestCase):
    def test_unsegmented_metric_is_the_server_deduplicated_union(self):
        client = mock.Mock()
        client.run_report.return_value = _response(7)
        result = ga4_query._run_user_report(
            client, "properties/123", [], "28daysAgo", "yesterday", None)
        self.assertEqual(result.users, 7)
        self.assertEqual(client.run_report.call_count, 1)

    def test_thresholded_union_is_not_given_a_precise_rate(self):
        client = mock.Mock()
        client.run_report.side_effect = [_response(20), _response(5, threshold=True)]
        cohort = ga4_query._run_user_report(client, "p", [], "28daysAgo", "yesterday", None)
        failures = ga4_query._run_user_report(client, "p", [], "28daysAgo", "yesterday", None)
        self.assertEqual(cohort.users, 20)
        self.assertEqual(failures.users, 5)
        self.assertTrue(failures.incomplete)
        self.assertFalse(cohort.incomplete)

    def test_sampled_failure_union_withholds_affected_user_rate(self):
        stdout = io.StringIO()
        args = SimpleNamespace(days_ago="28daysAgo", end_date="yesterday")
        with mock.patch.object(ga4_query, "_client", return_value=object()), \
             mock.patch.object(ga4_query, "_property", return_value="properties/123"), \
             mock.patch.object(ga4_query, "_registered_dimensions", return_value=set()), \
             mock.patch.object(ga4_query, "_run_user_report", side_effect=[
                 ga4_query._QueryResult(10),
                 ga4_query._QueryResult(4, incomplete=["GA4 sampling applied"]),
                 ga4_query._QueryResult(10),
                 ga4_query._QueryResult(None),
                 ga4_query._QueryResult(None)]), \
             contextlib.redirect_stdout(stdout):
            ga4_query.cmd_sync_reliability(args)
        self.assertIn("Affected-user rate: withheld", stdout.getvalue())
        self.assertNotIn("40.0% of observed sync users", stdout.getvalue())

    def test_incomplete_empty_population_is_not_reported_as_no_users(self):
        stdout = io.StringIO()
        args = SimpleNamespace(days_ago="28daysAgo", end_date="yesterday")
        with mock.patch.object(ga4_query, "_client", return_value=object()), \
             mock.patch.object(ga4_query, "_property", return_value="properties/123"), \
             mock.patch.object(ga4_query, "_registered_dimensions", return_value=set()), \
             mock.patch.object(ga4_query, "_run_user_report", side_effect=[
                 ga4_query._QueryResult(0),
                 ga4_query._QueryResult(0),
                 ga4_query._QueryResult(
                     0, incomplete=["GA4 returned an empty page early"]),
                 ga4_query._QueryResult(None),
                 ga4_query._QueryResult(None)]), \
             contextlib.redirect_stdout(stdout):
            ga4_query.cmd_sync_reliability(args)
        self.assertIn("Affected-user rate: withheld", stdout.getvalue())
        self.assertNotIn("no observed sync users", stdout.getvalue())

    def test_cli_exposes_requested_date_range(self):
        stdout = io.StringIO()
        args = SimpleNamespace(days_ago="28daysAgo", end_date="yesterday")
        with mock.patch.object(ga4_query, "_client", return_value=object()), \
             mock.patch.object(ga4_query, "_property", return_value="properties/123"), \
             mock.patch.object(ga4_query, "_registered_dimensions", return_value=None), \
             mock.patch.object(ga4_query, "_run_user_report", side_effect=[
                 ga4_query._QueryResult(10), ga4_query._QueryResult(2),
                 ga4_query._QueryResult(10)] +
                 [ga4_query._QueryResult(None) for _ in range(10)]), \
             contextlib.redirect_stdout(stdout):
            result = ga4_query.cmd_sync_reliability(args)
        self.assertEqual(result, 0)
        self.assertIn("28daysAgo through yesterday", stdout.getvalue())
        self.assertIn("20.0% of observed sync users", stdout.getvalue())
        self.assertIn("not physical unique phones", stdout.getvalue())

    def test_rates_use_observed_population_when_failures_exceed_login_starts(self):
        row = lambda name, n: SimpleNamespace(
            dimension_values=[SimpleNamespace(value=name)],
            metric_values=[SimpleNamespace(value=str(n))])
        stdout = io.StringIO()
        args = SimpleNamespace(days_ago="28daysAgo", end_date="yesterday")
        with mock.patch.object(ga4_query, "_client", return_value=object()), \
             mock.patch.object(ga4_query, "_property", return_value="properties/123"), \
             mock.patch.object(ga4_query, "_registered_dimensions",
                               return_value={"customEvent:failure_reason",
                                             "customEvent:outcome",
                                             "customEvent:stage",
                                             "customEvent:exception_kind",
                                             "customEvent:has_cached_data"}), \
             mock.patch.object(ga4_query, "_run_user_report", side_effect=[
                 ga4_query._QueryResult(2),
                 ga4_query._QueryResult(5),
                 ga4_query._QueryResult(5),
                 ga4_query._QueryResult(None, rows=[row("timeout", 3),
                                                    row("network_error", 2)]),
                 ga4_query._QueryResult(None), ga4_query._QueryResult(None),
                 ga4_query._QueryResult(None), ga4_query._QueryResult(None),
                 ga4_query._QueryResult(None), ga4_query._QueryResult(None)]), \
             contextlib.redirect_stdout(stdout):
            result = ga4_query.cmd_sync_reliability(args)
        output = stdout.getvalue()
        self.assertEqual(result, 0)
        self.assertIn("Login-start users: 2", output)
        self.assertIn("Observed sync population (login starts or failed sync/login events): 5", output)
        self.assertIn("Affected-user rate: 100.0% of observed sync users", output)
        self.assertIn("timeout: 3; 60.0% of observed sync users", output)
        self.assertIn("network_error: 2; 40.0% of observed sync users", output)
        self.assertIn("Breakdown failure outcome (", output)
        self.assertIn("Breakdown failure stage (", output)
        self.assertIn("Breakdown exception kind (", output)
        self.assertIn("Breakdown cached data (", output)
        self.assertNotIn("Affected-user rate: 250.0%", output)

    def test_thresholded_breakdown_does_not_print_bucket_percentages(self):
        row = SimpleNamespace(dimension_values=[SimpleNamespace(value="timeout")],
                              metric_values=[SimpleNamespace(value="3")])
        stdout = io.StringIO()
        args = SimpleNamespace(days_ago="28daysAgo", end_date="yesterday")
        with mock.patch.object(ga4_query, "_client", return_value=object()), \
             mock.patch.object(ga4_query, "_property", return_value="properties/123"), \
             mock.patch.object(ga4_query, "_registered_dimensions",
                               return_value={"customEvent:failure_reason"}), \
             mock.patch.object(ga4_query, "_run_user_report", side_effect=[
                 ga4_query._QueryResult(10), ga4_query._QueryResult(4),
                 ga4_query._QueryResult(10),
                 ga4_query._QueryResult(
                     None, rows=[row],
                     incomplete=["GA4 thresholding applied"]),
                 ga4_query._QueryResult(None), ga4_query._QueryResult(None)]), \
             contextlib.redirect_stdout(stdout):
            ga4_query.cmd_sync_reliability(args)
        self.assertIn("timeout: 3\n", stdout.getvalue())
        self.assertIn("failure reason: incomplete (GA4 thresholding applied)",
                      stdout.getvalue())
        self.assertIn("Breakdown failure stage: unavailable (GA4 custom dimension not registered)",
                      stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
