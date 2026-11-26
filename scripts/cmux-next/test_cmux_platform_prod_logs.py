#!/usr/bin/env python3
"""cmux-platform-prod-logs: dispatch only, an allowlisted service, non-empty needles, an exact parsed vm_/team_ id
that fails closed, and rows only in the private HQ issue store; the public log gets a count and a pointer.
Run by hand: python3 scripts/cmux-next/test_cmux_platform_prod_logs.py (no network, no credential)."""
import importlib.util
import io
import json
import os
import re
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-platform-prod-logs.yml")
_spec = importlib.util.spec_from_file_location("cmux_platform_prod_logs", os.path.join(HERE, "cmux-platform-prod-logs.py"))
logs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(logs)

VM = "vm_0000aaaa1111bbbb2222"
TEAM = "team_0000aaaa1111bbbb2222"
PROD = "cmux-platform-production"
STAGING = "cmux-platform-staging"
VM_PROD = "cmux-vm-production"
VM_STAGING = "cmux-vm-staging"
LISTED = "cloud platform edge"


def event(message, url="https://platform.example/v1/machines/" + VM + "/exec?token=abc", status=502):
    return {"timestamp": 1794400000000,
            "$metadata": {"type": "cf-worker", "message": message if isinstance(message, str) else json.dumps(message)},
            "$workers": {"outcome": "ok", "event": {"request": {"method": "POST", "url": url}, "response": {"status": status}}}}


def rows_for(events, ident, needles=(LISTED,)):
    return logs.publish(events, list(needles), ident)[1]


def run_main(args, env=None, stdin="fixture-token\n", response=None, upload="https://github.com/manaflow-ai/cmuxterm-hq/issues/9"):
    """main() with the network and the private store mocked; returns (exit, stdout, query mock, upload mock)."""
    output = io.StringIO()
    environ = {"GITHUB_EVENT_NAME": "workflow_dispatch", **(env or {})}
    response = response if response is not None else {"result": {"events": {"events": []}}}
    with patch.dict(logs.os.environ, environ), patch.object(logs.sys, "argv", ["logs", *args]), \
            patch.object(logs.sys, "stdin", io.StringIO(stdin)), patch.object(logs.sys, "stdout", output), \
            patch.object(logs, "query", return_value=response) as query, \
            patch.object(logs.base, "private_destination", return_value="fixture-hq-token"), \
            patch.object(logs.base, "private_upload", return_value=upload) as up:
        try:
            code = logs.main()
        except SystemExit as error:
            code = error
    return code, output.getvalue(), query, up


def event_file(inputs):
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"inputs": inputs}, f)
    f.close()
    return f.name


class WorkflowTests(unittest.TestCase):
    """The workflow file itself: what may start the job and what it may read."""

    @classmethod
    def setUpClass(cls):
        with open(WORKFLOW) as f:
            cls.text = f.read()

    def block(self, key):
        """A top-level YAML block's body: the lines after `key:` up to the next unindented key."""
        m = re.search(rf"^{key}:\n((?:[ #].*\n|\n)*)", self.text, re.M)
        self.assertIsNotNone(m, f"no top-level {key}:")
        return m.group(1)

    def test_dispatch_is_the_only_trigger(self):
        triggers = re.findall(r"^  ([A-Za-z_]+):", self.block("on"), re.M)
        self.assertEqual(triggers, ["workflow_dispatch"])
        for other in ("push", "pull_request", "schedule", "workflow_run", "workflow_call", "repository_dispatch"):
            self.assertNotRegex(self.block("on"), rf"^\s+{other}:", other)

    def test_the_job_runs_only_for_a_dispatch_from_feat_cmux_next(self):
        self.assertRegex(self.text, r"(?m)^    if: github\.event_name == 'workflow_dispatch' && "
                                    r"github\.ref == 'refs/heads/feat-cmux-next'$")
        self.assertEqual(len(re.findall(r"(?m)^  [a-z][a-z0-9_-]*:$", self.block("jobs"))), 1)

    def test_the_service_is_a_choice_of_the_platform_and_cmux_vm_workers(self):
        on = self.block("on")
        self.assertRegex(on, r"(?m)^      service:\n(?:        .*\n)*?        type: choice\n")
        options = re.search(r"(?m)^        options: \[([^\]]*)\]$", on)
        self.assertIsNotNone(options)
        self.assertEqual({o.strip() for o in options.group(1).split(",")}, {PROD, STAGING, VM_PROD, VM_STAGING})
        self.assertEqual(set(logs.SERVICES), {PROD, STAGING, VM_PROD, VM_STAGING})

    def test_id_and_needles_are_required_and_never_in_step_env(self):
        on = self.block("on")
        for name in ("id", "needles"):
            self.assertRegex(on, rf"(?m)^      {name}:\n(?:        .*\n)*?        required: true\n", name)
            self.assertNotIn(f"inputs.{name}", self.block("jobs"), name)
        self.assertNotIn("inputs.service", self.block("jobs"))
        self.assertIn('--from-event "$GITHUB_EVENT_PATH"', self.text)

    def test_existing_credentials_only_and_read_only_contents(self):
        self.assertRegex(self.text, r"(?m)^permissions:\n  contents: read\n")
        self.assertRegex(self.text, r"(?m)^    environment: cmux-next-production$")
        self.assertEqual(set(re.findall(r"secrets\.([A-Z0-9_]+)", self.text)), {"CLOUDFLARE_API_TOKEN", "GLAEDA_ROUTE_APP_KEY"})
        self.assertIn("repositories: cmuxterm-hq", self.text)
        self.assertIn("permission-issues: write", self.text)

    def test_the_public_log_gets_only_the_scripts_count_and_pointer(self):
        self.assertNotRegex(self.text, r"upload-artifact|actions/cache")
        self.assertIn("python3 -I scripts/cmux-next/cmux-platform-prod-logs.py", self.text)
        self.assertIn("sparse-checkout: |", self.text)
        for path in ("scripts/cmux-next/cmux-platform-prod-logs.py", "scripts/cmux-next/cmux-api-prod-logs.py"):
            self.assertIn(path, self.text)


class GuardTests(unittest.TestCase):
    def test_a_push_never_queries(self):
        path = event_file({"service": PROD, "id": TEAM, "needles": LISTED})
        try:
            code, out, query, _ = run_main(["--from", "2026-11-11T13:20:00Z", "--from-event", path],
                                           env={"GITHUB_EVENT_NAME": "push"})
        finally:
            os.unlink(path)
        self.assertRegex(str(code), "only workflow_dispatch")
        query.assert_not_called()
        self.assertEqual(out, "")

    def test_empty_needles_refuse_before_query(self):
        for needles in ("", " , ", ","):
            with self.subTest(needles=needles):
                code, _, query, _ = run_main(["--from", "2026-11-11T13:20:00Z", "--service", PROD, "--id", TEAM,
                                              "--needles", needles])
                self.assertRegex(str(code), "at least one search term")
                query.assert_not_called()
        with self.assertRaisesRegex(ValueError, "at least one search term"):
            logs.publish([event({"msg": LISTED, "team": TEAM})], [], TEAM)

    def test_a_malformed_needle_refuses_before_query(self):
        code, _, query, _ = run_main(["--from", "2026-11-11T13:20:00Z", "--service", PROD, "--id", TEAM,
                                      "--needles", "ok text,a\"b"])
        self.assertRegex(str(code), "needles: each")
        query.assert_not_called()

    def test_only_the_listed_workers_are_read(self):
        for service in ("", "cmux-api", "cmux-platform-development", "cmux-vm-preview", PROD + " ", "cmux-platform-*"):
            with self.subTest(service=service):
                code, _, query, _ = run_main(["--from", "2026-11-11T13:20:00Z", "--service", service, "--id", TEAM,
                                              "--needles", LISTED])
                self.assertRegex(str(code), "service: one of")
                query.assert_not_called()

    def test_an_unparsed_id_refuses_before_query(self):
        for ident in ("", "team_", "vm_", "machine_abc", "user_abc", "VM_abc", "team_a,team_b", "vm_a b",
                      "team_" + "a" * 70, " team_abc", "team_abc\n", "*"):
            with self.subTest(ident=ident):
                code, _, query, _ = run_main(["--from", "2026-11-11T13:20:00Z", "--service", PROD, "--id", ident,
                                              "--needles", LISTED])
                self.assertRegex(str(code), "exact vm_ or team_ id")
                query.assert_not_called()

    def test_window_counts_every_event_by_shape_with_no_id(self):
        failed = event({"msg": "cloud machine guest rpc failed", "op": "exec", "failure": "unreachable", "team": TEAM,
                        "machine": VM, "ms": 12, "why": "free text hunter2"}, status=503)
        failed["$workers"]["scriptVersion"] = {"id": "0f0e0d0c-1111-2222-3333-444455556666"}
        reset = event("not json", status=200)
        reset["$workers"]["outcome"] = "canceled"
        path = event_file({"service": PROD, "id": "window", "needles": "12:"})
        try:
            code, out, query, upload = run_main(["--from", "2026-11-11T13:20:00Z", "--from-event", path],
                                                response={"result": {"events": {"events": [failed, failed, reset]}}})
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        _, header, rows = upload.call_args.args
        self.assertEqual((header["id_kind"], header["id"], header["events_scanned"]), ("window", "window", 3))
        self.assertEqual(sorted(r["n"] for r in rows), [1, 2])
        rpc = next(r for r in rows if r["n"] == 2)
        self.assertEqual(rpc["log"], {"msg": "cloud machine guest rpc failed", "op": "exec", "failure": "unreachable",
                                      "ms": 12})
        self.assertEqual((rpc["status"], rpc["version"]), (503, logs.base.tag("0f0e0d0c-1111-2222-3333-444455556666")))
        self.assertEqual(next(r for r in rows if r["n"] == 1)["outcome"], "canceled")
        text = json.dumps(rows) + out
        for leak in (TEAM, VM, logs.base.tag(TEAM), logs.base.tag(VM), "hunter2", "token=abc"):
            self.assertNotIn(leak, text)

    def test_cmux_vm_window_counts_provider_failures_by_operation_and_status(self):
        # cmux-platform#1442: Effect text lines of cmux-vm (src/upstream/live.ts logUpstreamFailure).
        def vm_line(operation, status, extra=""):
            return event(f'timestamp=2026-11-16T13:55:01.000Z level=WARN fiber=#12 message="cmux-vm upstream call failed" '
                         f'operation={operation} status={status}{extra}',
                         url="https://vm.example/v1/vms/" + VM + "/pause", status=503)
        pause = vm_line("pauseVm", "503", ' cause="hunter2 ' + VM + '"')
        timeout = vm_line("startVm", "none")
        other = event('timestamp=x level=INFO fiber=#1 message="free text hunter2"', status=200)
        path = event_file({"service": VM_PROD, "id": "window", "needles": "12:"})
        try:
            code, out, query, upload = run_main(["--from", "2026-11-16T13:30:00Z", "--from-event", path],
                                                response={"result": {"events": {"events": [pause, pause, timeout, other]}}})
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        self.assertEqual(query.call_args.args[1], VM_PROD)
        _, header, rows = upload.call_args.args
        self.assertEqual((header["service"], header["id"], header["logs_dropped_unlisted"]), (VM_PROD, "window", 1))
        by_op = {r["log"]["operation"]: r for r in rows if "log" in r}
        self.assertEqual(by_op["pauseVm"]["log"], {"msg": "cmux-vm upstream call failed", "level": "warn",
                                                   "operation": "pauseVm", "status": 503})
        self.assertEqual(by_op["pauseVm"]["n"], 2)
        self.assertEqual(by_op["pauseVm"]["path"], "/v1/vms/*/pause")
        self.assertEqual(by_op["startVm"]["log"]["status"], "none")
        text = json.dumps(rows) + out
        for leak in (VM, logs.base.tag(VM), "hunter2"):
            self.assertNotIn(leak, text)

    def test_cmux_vm_refuses_an_id_scoped_read(self):
        path = event_file({"service": VM_STAGING, "id": VM, "needles": "pause"})
        try:
            code, _, query, upload = run_main(["--from", "2026-11-16T13:30:00Z", "--from-event", path])
        finally:
            os.unlink(path)
        self.assertNotEqual(code, 0)
        query.assert_not_called()
        upload.assert_not_called()

    def test_inputs_come_from_the_event_file_and_stdout_is_count_and_pointer(self):
        own = event({"msg": LISTED, "machine": VM, "outcome": "refused"})
        foreign = event({"msg": LISTED, "machine": "vm_foreign"})
        path = event_file({"service": STAGING, "id": VM, "needles": LISTED})
        try:
            code, out, query, upload = run_main(["--from", "2026-11-11T13:20:00Z", "--from-event", path],
                                                response={"result": {"events": {"events": [own, foreign]}}})
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        self.assertEqual(query.call_args.args[1], STAGING)
        token, header, rows = upload.call_args.args
        self.assertEqual(token, "fixture-hq-token")
        self.assertEqual((header["service"], header["id_kind"], header["id"]), (STAGING, "vm", logs.base.tag(VM)))
        self.assertEqual(header["events_in_window"], 1)
        self.assertEqual([r["log"]["machine"] for r in rows], [logs.base.tag(VM)])
        self.assertEqual(json.loads(out), {"row_count": 1, "pointer": "https://github.com/manaflow-ai/cmuxterm-hq/issues/9"})
        for leak in (VM, logs.base.tag(VM), LISTED, "refused", "fixture-token", "fixture-hq-token"):
            self.assertNotIn(leak, out)

    def test_the_private_store_is_verified_before_any_query(self):
        args = ["--from", "2026-11-11T13:20:00Z", "--service", PROD, "--id", TEAM, "--needles", LISTED]
        for repo in ({"private": False, "full_name": logs.base.HQ_REPO}, {"private": True, "full_name": "someone/else"}, None):
            with self.subTest(repo=repo), \
                    patch.dict(logs.os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch", "HQ_GH_TOKEN": "fixture-hq-token"}), \
                    patch.object(logs.sys, "argv", ["logs", *args]), \
                    patch.object(logs.base, "hq_request", return_value=repo), patch.object(logs, "query") as query:
                with self.assertRaisesRegex(SystemExit, "expected private repository"):
                    logs.main()
                query.assert_not_called()

    def test_a_failed_private_upload_prints_nothing(self):
        output = io.StringIO()
        response = {"result": {"events": {"events": [event({"msg": LISTED, "team": TEAM})]}}}
        args = ["logs", "--from", "2026-11-11T13:20:00Z", "--service", PROD, "--id", TEAM, "--needles", LISTED]
        with patch.dict(logs.os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch"}), \
                patch.object(logs.sys, "argv", args), patch.object(logs.sys, "stdin", io.StringIO("fixture-token\n")), \
                patch.object(logs.sys, "stdout", output), patch.object(logs, "query", return_value=response), \
                patch.object(logs.base, "private_destination", return_value="fixture-hq-token"), \
                patch.object(logs.base, "private_upload", side_effect=SystemExit("private log store refused: HTTP 403")):
            with self.assertRaisesRegex(SystemExit, "private log store refused"):
                logs.main()
        self.assertEqual(output.getvalue(), "")


class IdFilterTests(unittest.TestCase):
    def test_a_machine_id_keeps_only_lines_parsed_as_that_machine(self):
        own = event({"msg": LISTED, "machine": VM})
        alias = event({"msg": LISTED, "machineId": VM, "team": "team_any"})
        foreign = event({"msg": LISTED, "machine": "vm_foreign"}, url="https://platform.example/v1/machines/" + VM)
        missing = event({"msg": LISTED}, url="https://platform.example/v1/machines/" + VM)
        team_only = event({"msg": LISTED, "team": TEAM})
        self.assertEqual(len(rows_for([own, alias, foreign, missing, team_only], VM)), 2)

    def test_a_team_id_keeps_only_lines_parsed_as_that_team(self):
        own = event({"msg": LISTED, "team": TEAM, "machine": "vm_any"})
        alias = event({"msg": LISTED, "teamId": TEAM})
        foreign = event({"msg": LISTED, "team": "team_foreign"}, url="https://platform.example/v1/teams/" + TEAM)
        machine_only = event({"msg": LISTED, "machine": VM})
        self.assertEqual(len(rows_for([own, alias, foreign, machine_only], TEAM)), 2)

    def test_conflicts_duplicates_and_non_strings_fail_closed(self):
        cases = [
            event({"msg": LISTED, "machine": VM, "machineId": "vm_foreign"}),
            event({"msg": LISTED, "machine": VM, "vm": {"id": VM}}),
            event('{"msg":"' + LISTED + '","machine":"vm_foreign","machine":"' + VM + '"}'),
            event({"msg": LISTED, "machine": VM + "-suffix"}),
            event({"msg": LISTED, "machine": None}),
            event({"msg": LISTED, "machine": [VM]}),
            event("plain text that mentions " + VM),
        ]
        conflicting_source = event({"msg": LISTED, "machine": VM})
        conflicting_source["source"] = {"msg": LISTED, "machine": "vm_foreign"}
        cases.append(conflicting_source)
        for i, candidate in enumerate(cases):
            with self.subTest(case=i):
                self.assertEqual(rows_for([candidate], VM), [])
        self.assertEqual(rows_for([event({"msg": LISTED, "team": TEAM, "teamId": "team_foreign"})], TEAM), [])

    def test_a_production_event_with_plain_message_text_keeps_its_source_id(self):
        # Workers Logs' shape: $metadata.message is the line's msg text, source the parsed line. Every production
        # team and vm read until 2026-11-22 kept 0 events (hq#18697, hq#18725) because the plain text failed closed.
        own = event(LISTED)
        own["source"] = {"msg": LISTED, "team": TEAM}
        foreign = event(LISTED)
        foreign["source"] = {"msg": LISTED, "team": "team_foreign"}
        bare = event(LISTED)
        self.assertEqual(len(rows_for([own, foreign, bare], TEAM)), 1)
        dup = event(LISTED)
        dup["source"] = '{"msg":"' + LISTED + '","team":"team_foreign","team":"' + TEAM + '"}'
        self.assertEqual(rows_for([dup], TEAM), [])

    def test_scope_comes_before_counts(self):
        good = event({"msg": LISTED, "team": TEAM})
        bad = event({"msg": "private text from another team", "team": "team_foreign"})
        head, rows = logs.publish([good, bad], [LISTED], TEAM)
        self.assertEqual(head["events_in_window"], 1)
        # The window's own count, before the id filter: zero here says the query read nothing, not that no row was
        # this id's (the 12:50Z read, hq#11503, could not tell the two apart).
        self.assertEqual(head["events_scanned"], 2)
        self.assertNotIn("logs_dropped_unlisted", head)
        self.assertEqual(len(rows), 1)


class ProjectionTests(unittest.TestCase):
    def test_an_unlisted_or_tenant_line_never_reaches_a_row(self):
        for line, why in (({"msg": "the merger closes friday", "team": TEAM}, "unlisted"),
                          ({"msg": LISTED + ": hunter2", "team": TEAM}, "unlisted"),
                          ({"msg": LISTED, "team": TEAM, "source": "automation", "run": "r1"}, "tenant")):
            with self.subTest(line=line):
                counts = {}
                row = logs.line(event(line), counts)
                self.assertNotIn("log", row)
                self.assertEqual(counts, {f"logs_dropped_{why}": 1})
                self.assertNotIn("merger", json.dumps(row))
                self.assertNotIn("hunter2", json.dumps(row))

    def test_a_listed_line_keeps_typed_fields_with_ids_hashed(self):
        row = logs.line(event({"msg": LISTED, "team": TEAM, "machine": VM, "outcome": "refused", "status": 409,
                               "error": "upstream said hunter2", "why": "free text with spaces", "body": {"k": "v"}}))
        self.assertEqual(row["log"], {"msg": LISTED, "team": logs.base.tag(TEAM), "machine": logs.base.tag(VM),
                                      "outcome": "refused", "status": 409, "error": True})
        text = json.dumps(row)
        for leak in (TEAM, VM, "hunter2", "token=abc", "free text"):
            self.assertNotIn(leak, text)

    def test_the_spare_gateway_read_keeps_its_booleans_and_mode(self):
        # cmux-platform#1629: the 2026-11-22 09:13Z gateway claim's line was dropped unlisted (hq#18324).
        for mode, kept in (("gateway", "gateway"), (None, "null"), ("unread", "unread")):
            with self.subTest(mode=mode):
                row = logs.line(event({"msg": "cloud.spare.gateway_read", "team": TEAM, "lacks": True,
                                       "shared": False, "host": "yes", "mode": mode}))
                self.assertEqual(row["log"], {"msg": "cloud.spare.gateway_read", "team": logs.base.tag(TEAM),
                                              "mode": kept, "lacks": True, "shared": False})
                self.assertNotIn(TEAM, json.dumps(row))

    def test_a_spare_claim_keeps_its_skip_reasons_steps_and_path(self):
        # Production 2026-11-26 16:09Z: a claim saw one spare and created, and the row read only `spares: 1` (hq#29939).
        row = logs.line(event({"msg": "machines.spare.claim", "team": TEAM, "spares": 1,
                               "skipped": {"warming": 1, "lost_generation": 2, "Bad Key": 3, "paused": "x",
                                           "vm_0123456789abcdef": 1},
                               "ms": {"leases": 4, "total": 95, "nested": {"x": 1}},
                               "path": "created", "fallback": "all_skipped", "behind": 0}))
        self.assertEqual(row["log"], {"msg": "machines.spare.claim", "team": logs.base.tag(TEAM), "spares": 1,
                                      "path": "created", "fallback": "all_skipped", "behind": 0,
                                      "skipped": {"lost_generation": 2, logs.base.tag("vm_0123456789abcdef"): 1,
                                                  "warming": 1},
                                      "ms": {"leases": 4, "total": 95}})
        self.assertNotIn(TEAM, json.dumps(row))
        self.assertNotIn("vm_0123456789abcdef", json.dumps(row))

    def test_a_cut_off_submit_answer_keeps_its_op_and_wait(self):
        # cmux-platform retro r2b92b756: a start that ran out its 25 s answer wait was retried silently, so only this
        # line counts how often an op outlives its request.
        row = logs.line(event({"msg": "cloud.submit.cut_off", "machine": "vm_cutoff", "op": "start", "ms": 25001}))
        self.assertEqual(row["log"], {"msg": "cloud.submit.cut_off", "machine": logs.base.tag("vm_cutoff"),
                                      "op": "start", "ms": 25001})
        self.assertNotIn("vm_cutoff", json.dumps(row))

    def test_a_work_machine_line_keeps_its_size_policy_and_why(self):
        # RFD agent-work-placement (cmux-platform#2099 start size, #2108 turn_end pause): worker-log-read.yml gets 403
        # on production, so only this persisted read can count work VMs by size and pause policy before and after.
        row = logs.line(event({"msg": "cloud.work_machine.started", "pause_policy": "turn_end", "team": TEAM,
                               "machine": VM, "work": "vm_work1", "cpu": 8, "memory_mb": 16384, "ms": 2100}))
        self.assertEqual(row["log"], {"msg": "cloud.work_machine.started", "team": logs.base.tag(TEAM),
                                      "machine": logs.base.tag(VM), "work": logs.base.tag("vm_work1"), "cpu": 8,
                                      "memory_mb": 16384, "ms": 2100, "pause_policy": "turn_end"})
        for why, kept in (("budget", "budget"), ("said hunter2 here", "other")):
            with self.subTest(why=why):
                row = logs.line(event({"msg": "cloud.work_machine.skipped", "team": TEAM, "why": why}))
                self.assertEqual(row["log"]["why"], kept)
        row = logs.line(event({"msg": "cloud.work_machine.started", "pause_policy": "made_up"}))
        self.assertEqual(row["log"]["pause_policy"], "other")
        for leak in (TEAM, VM, "vm_work1", "hunter2"):
            self.assertNotIn(leak, json.dumps(row))

    def test_a_window_counts_work_machines_with_no_id(self):
        events = [event({"msg": "cloud.work_machine.started", "pause_policy": "turn_end", "team": TEAM,
                         "machine": VM, "work": "vm_work1", "cpu": 8, "memory_mb": 16384})] * 2
        head, rows = logs.window_totals(events, ["cloud.work_machine.started"])
        self.assertEqual([r["log"] for r in rows], [{"msg": "cloud.work_machine.started", "cpu": 8,
                                                     "memory_mb": 16384, "pause_policy": "turn_end"}])
        self.assertEqual(rows[0]["n"], 2)
        for leak in (TEAM, VM, "vm_work1", logs.base.tag("vm_work1")):
            self.assertNotIn(leak, json.dumps(rows))

    def test_the_msg_allowlist_is_exact_constant_ids(self):
        self.assertIn(LISTED, logs.PLATFORM_MSGS)
        self.assertIn("machines.spare.claim", logs.PLATFORM_MSGS)
        self.assertTrue(all(isinstance(m, str) and "${" not in m and m == m.strip() for m in logs.PLATFORM_MSGS))


class NeverBoundTests(unittest.TestCase):
    """Prod journey 45767907054 (2026-11-26 06:42Z): a cold create's VM was made and its bind token minted, then it sat
    `provisioning, host null` until never_bound. The platform logged its trace and its guest probe, and this reader
    dropped both. These keep the step a create reached and the guest's typed facts, never its addresses or hosts."""

    PROBE_OUT = ("uptime_s=301.52\nbind_file=present\nnameservers=10.0.0.2,\nroute=default via 10.0.0.1 dev eth0\n"
                 "dns api.cmux.example=203.0.113.9\ndns coderouter.cmux.internal=unresolved\n"
                 "https https://api.cmux.example/v1/cloud/bind http=405 ip=203.0.113.9 connect_s=0.01 tls_s=0.02 "
                 "total_s=0.05\nhttps https://coderouter.cmux.internal/ curl: (6) Could not resolve host: "
                 "coderouter.cmux.internal http=000 ip= connect_s=0 tls_s=0 total_s=0.001\n")

    def test_a_create_trace_keeps_its_listed_steps_in_order(self):
        row = logs.line(event({"msg": "cloud.create.trace", "machine": VM, "attempt": 1, "outcome": "ok",
                               "steps": {"edge": 900, "driver": 400, "ensure": 24800, "secret_thing": 5,
                                         "bind_file": "x"}, "power": {"call_ms": 3}, "total_ms": 31000}))
        self.assertEqual(row["log"], {"msg": "cloud.create.trace", "machine": logs.base.tag(VM), "outcome": "ok",
                                      "attempt": 1, "total_ms": 31000,
                                      "steps": {"driver": 400, "edge": 900, "ensure": 24800}})
        self.assertEqual(list(row["log"]["steps"]), ["driver", "edge", "ensure"])
        for msg in ("cloud.create.submit", "cloud.start.submit", "cloud.start.trace"):
            self.assertIn(msg, logs.PLATFORM_MSGS)

    def test_a_never_bound_line_keeps_the_probe_as_typed_facts_only(self):
        row = logs.line(event({"msg": "cloud.machine.start_overdue", "team": TEAM, "machine": VM,
                               "code": "cloud.machine.never_bound", "ms": 305000, "create_running": False,
                               "bind_probe": {"outcome": "ran", "ms": 4100, "exit": 0, "out": self.PROBE_OUT,
                                              "truncated": False}}))
        log = row["log"]
        self.assertIs(log["create_running"], False)
        self.assertEqual(log["bind_probe"], {"outcome": "ran", "ms": 4100, "exit": 0, "truncated": False,
                                             "uptime": "300s-900s", "bind_file": "present", "nameservers": 1,
                                             "route": "default", "dns_api": "resolved", "dns_edge": "unresolved",
                                             "https_api": 405, "https_edge": "curl_6"})
        text = json.dumps(row)
        for secret in ("203.0.113", "10.0.0", "cmux.example", "coderouter.cmux.internal", "eth0", VM, TEAM):
            self.assertNotIn(secret, text)

    def test_every_probe_outcome_and_odd_out_text_stays_typed(self):
        cases = (({"outcome": "failed", "ms": 15, "error": "VmNotRunning"}, {"outcome": "failed", "ms": 15,
                                                                          "error": True}),
                 ({"outcome": "failed", "ms": 15, "error": "cloud.vm.not_running"},
                  {"outcome": "failed", "ms": 15, "error": "cloud.vm.not_running"}),
                 ({"outcome": "no_route", "ms": 0}, {"outcome": "no_route", "ms": 0}),
                 ({"outcome": "weird", "ms": -1}, {"outcome": "other"}),
                 ({"outcome": "ran", "ms": 9, "exit": 0, "out": "uptime_s=12\nbind_file=missing\nroute=\ncurl=absent\n"},
                  {"outcome": "ran", "ms": 9, "exit": 0, "uptime": "lt60s", "bind_file": "missing", "route": "none",
                   "https_api": "curl_absent", "https_edge": "curl_absent"}),
                 ({"outcome": "ran", "ms": 9, "out": "https https://a/ http=000 ip= total_s=3\nuptime_s=nan?x"},
                  {"outcome": "ran", "ms": 9, "https_api": "no_answer"}))
        for probe, want in cases:
            with self.subTest(probe=probe):
                row = logs.line(event({"msg": "cloud.machine.start_overdue", "machine": VM,
                                       "code": "cloud.machine.never_bound", "bind_probe": probe}))
                self.assertEqual(row["log"]["bind_probe"], want)


class IdleKeptTests(unittest.TestCase):
    """cmux#54889: how many overdue machines stayed up only for the disabled cmux-chief-update.timer, from a window
    read, with no machine, team or guest-written name in a row."""

    def kept(self, **fields):
        return {"msg": "cloud.idle.kept", "team": TEAM, "machine": VM, "running_s": 7300, "daemon": "0.42.1", **fields}

    def test_a_timer_only_workload_line_says_so_and_nothing_else_of_the_guest(self):
        timer = self.kept(why="workload", workload={"busy": 0, "listening": 0, "timers": 1, "process_names": [],
                                                     "ports": [], "timer_names": ["systemd:cmux-chief-update.timer"]})
        row = logs.line(event(timer))
        self.assertEqual(row["log"], {"msg": "cloud.idle.kept", "why": "workload", "team": logs.base.tag(TEAM),
                                      "machine": logs.base.tag(VM), "timer_only": True, "daemon": "0.42.1",
                                      "running": "1h-6h"})

    def test_any_other_workload_is_not_timer_only_and_its_names_never_print(self):
        for workload in ({"busy": 1, "timer_names": ["systemd:cmux-chief-update.timer"], "process_names": ["hunter2"]},
                         {"busy": 0, "listening": 1, "ports": [8443], "timer_names": ["systemd:cmux-chief-update.timer"]},
                         {"timer_names": ["systemd:cmux-chief-update.timer", "systemd:hunter2-backup.timer"]},
                         {"timer_names": []}, {"timer_names": "systemd:cmux-chief-update.timer"}):
            with self.subTest(workload=workload):
                row = logs.line(event(self.kept(why="workload", workload=workload)))
                self.assertIs(row["log"]["timer_only"], False)
                self.assertNotIn("hunter2", json.dumps(row))
                self.assertNotIn("8443", json.dumps(row))

    def test_reasons_are_a_fixed_set_and_bands_and_versions_are_coarse(self):
        cases = ((dict(why="recent", running_s=59), {"why": "recent", "running": "lt1h"}),
                 (dict(why="no report today", running_s=90000), {"why": "other", "running": "ge24h"}),
                 (dict(why="sessions", daemon=None), {"why": "sessions", "daemon": "null"}),
                 (dict(why="held", daemon="has spaces 1"), {"why": "held"}))
        for fields, want in cases:
            with self.subTest(fields=fields):
                log = logs.line(event(self.kept(**fields)))["log"]
                for k, v in want.items():
                    self.assertEqual(log.get(k), v)
                self.assertNotIn("timer_only", log)
                self.assertNotIn("spaces", json.dumps(log))
                self.assertNotIn("running_s", log)

    def test_a_window_counts_timer_only_lines_with_no_id(self):
        timer = event(self.kept(why="workload", workload={"timer_names": ["systemd:cmux-chief-update.timer"]}))
        path = event_file({"service": PROD, "id": "window", "needles": "cloud.idle.kept"})
        try:
            code, out, query, upload = run_main(["--from", "2026-11-23T06:00:00Z", "--minutes", "60",
                                                 "--from-event", path],
                                                response={"result": {"events": {"events": [timer, timer]}}})
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        self.assertEqual(query.call_args.kwargs.get("needle"), "cloud.idle.kept")
        _, _, rows = upload.call_args.args
        self.assertEqual([(r["log"]["timer_only"], r["n"]) for r in rows], [(True, 2)])
        text = json.dumps(rows) + out
        for leak in (TEAM, VM, logs.base.tag(TEAM), logs.base.tag(VM)):
            self.assertNotIn(leak, text)

    def test_only_a_lone_allowlisted_msg_reaches_the_query(self):
        self.assertEqual(logs.window_needle(["cloud.idle.kept"]), "cloud.idle.kept")
        self.assertIsNone(logs.window_needle(["cloud.idle.kept", "workload"]))
        self.assertIsNone(logs.window_needle(["hunter2 secret"]))


class QueryTests(unittest.TestCase):
    def test_the_query_filters_on_the_chosen_service_in_the_shared_account(self):
        sent = []

        class Reply(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout):
            sent.append(request)
            return Reply(b'{"result": {"events": {"events": []}}}')

        with patch.object(logs.urllib.request, "urlopen", side_effect=urlopen):
            logs.query("fixture-token", STAGING, 1, 2)
        body = json.loads(sent[0].data)
        self.assertEqual(body["parameters"]["filters"],
                         [{"key": "$metadata.service", "operation": "eq", "type": "string", "value": STAGING}])
        self.assertIn(f"/accounts/{logs.base.ACCOUNT}/workers/observability/telemetry/query", sent[0].full_url)

    def test_a_refused_query_says_only_the_status(self):
        error = urllib.error.HTTPError("https://x", 403, "Forbidden", {}, io.BytesIO(b'{"errors":[{"message":"secret detail"}]}'))
        with patch.object(logs.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(SystemExit) as raised:
                logs.query("fixture-token", PROD, 1, 2)
        self.assertEqual(str(raised.exception), "telemetry query refused: HTTP 403")


class IdNeedleTests(unittest.TestCase):
    """An id-scoped read asks the telemetry query for the id's own events (its `needle`). Production logs more events in
    an hour than the reader's PAGES pages hold: the service filter alone returned 20000 events, none of them the id's
    (hq#13055 and hq#13057: events_scanned 20000, truncated, 0 in window), for a team whose creates logged in it."""

    def test_an_id_scoped_read_sends_the_id_as_the_query_needle(self):
        for ident in (VM, TEAM):
            with self.subTest(ident=ident):
                code, _, query, _ = run_main(["--from", "2026-11-11T13:20:00Z", "--service", PROD, "--id", ident,
                                              "--needles", LISTED])
                self.assertEqual(code, 0)
                self.assertEqual(query.call_args.kwargs.get("needle"), ident)

    def test_every_page_of_an_id_read_carries_the_needle(self):
        full = [{"$metadata": {"id": f"e{i}"}} for i in range(1000)]
        replies = [{"result": {"events": {"events": full}}}, {"result": {"events": {"events": []}}}]
        output = io.StringIO()
        with patch.dict(logs.os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch"}), \
                patch.object(logs.sys, "argv", ["logs", "--from", "2026-11-11T13:20:00Z", "--service", PROD,
                                                "--id", TEAM, "--needles", LISTED]), \
                patch.object(logs.sys, "stdin", io.StringIO("fixture-token\n")), patch.object(logs.sys, "stdout", output), \
                patch.object(logs, "query", side_effect=replies) as query, \
                patch.object(logs.base, "private_destination", return_value="fixture-hq-token"), \
                patch.object(logs.base, "private_upload", return_value="https://example/issues/9"):
            self.assertEqual(logs.main(), 0)
        self.assertEqual(query.call_count, 2)
        self.assertEqual([c.kwargs.get("needle") for c in query.call_args_list], [TEAM, TEAM])
        self.assertEqual(query.call_args_list[1].args[4], "e999")

    def test_a_window_read_sends_no_needle(self):
        code, _, query, _ = run_main(["--from", "2026-11-11T13:20:00Z", "--service", VM_PROD, "--id", "window",
                                      "--needles", "cmux-vm"])
        self.assertEqual(code, 0)
        self.assertIsNone(query.call_args.kwargs.get("needle"))

    def test_the_query_body_carries_the_needle_exactly(self):
        sent = []

        class Reply(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout):
            sent.append(request)
            return Reply(b'{"result": {"events": {"events": []}}}')

        with patch.object(logs.urllib.request, "urlopen", side_effect=urlopen):
            logs.query("fixture-token", PROD, 1, 2, needle=VM)
            logs.query("fixture-token", PROD, 1, 2)
        with_id, without = (json.loads(r.data) for r in sent)
        self.assertEqual(with_id["parameters"]["needle"], {"value": VM, "isRegex": False, "matchCase": True})
        self.assertNotIn("needle", without["parameters"])


if __name__ == "__main__":
    unittest.main()
