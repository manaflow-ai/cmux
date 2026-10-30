#!/usr/bin/env python3
"""Tests for assign-ipc-method-ids.py (p05-ipc-011): append-only ids, one family per name, Q6 empty."""

from __future__ import annotations

import copy
import importlib.util
import json
import re
import sys
import unittest
import unittest.mock
from pathlib import Path

SCRIPT = Path(__file__).with_name("assign-ipc-method-ids.py")
SPEC = importlib.util.spec_from_file_location("assign_ipc_method_ids", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
ASSIGN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ASSIGN  # dataclasses resolve the module by name
SPEC.loader.exec_module(ASSIGN)

NO_SOURCES = ASSIGN.Sources(macos=set, cli=set, ios=set, swift_spawning=set)
CORE = ASSIGN.ROOT / "cmux-tui/crates/cmux-tui-core/src"


def live() -> dict:
    return json.loads(ASSIGN.SCHEMA.read_text())


def probe(document: dict) -> dict:
    """A copy of `ping` without its IPC attributes, to add under a new wire name."""

    entry = copy.deepcopy(document["commands"]["ping"])
    for key in ASSIGN.COMMAND_KEY_ORDER:
        entry.pop(key, None)
    return entry


def daemon_method_classes() -> dict[str, str]:
    """Wire name -> MethodClass of the daemon's command table (command_names.rs)."""

    text = (CORE / "server/command_names.rs").read_text()
    return {wire: method_class for wire, method_class in re.findall(r'=>\s*"([^"]+)",\s*(\w+);', text)}


class LiveSchemaTests(unittest.TestCase):
    def test_live_schema_is_current_and_q6_is_empty(self) -> None:
        self.assertEqual(ASSIGN.main(["--check"]), 0)
        self.assertEqual(ASSIGN.missing_attributes(live()), [])

    def test_every_independent_command_is_read_only_and_not_stream_scoped(self) -> None:
        for name, command in live()["commands"].items():
            if command.get("ordering") == "independent":
                self.assertEqual(command["durability"], "read_only", name)
                self.assertNotIn("stream_scoped", command, name)

    def test_second_run_changes_nothing(self) -> None:
        document = live()
        assigner = ASSIGN.Assigner(copy.deepcopy(document))
        self.assertEqual(ASSIGN.render(assigner.run()), ASSIGN.render(document))
        self.assertEqual(assigner.changes, [])

    def test_commands_writing_one_pty_input_share_a_priority(self) -> None:
        commands = live()["commands"]
        writers = ("send", "send-key", "paste-image")
        self.assertEqual({commands[name]["priority"] for name in writers}, {"input"})

    def test_bulk_commands_are_reads_or_reviewed_stream_writes(self) -> None:
        for name, command in live()["commands"].items():
            if command["priority"] == "bulk" and name not in ASSIGN.BULK_STREAM_WRITES:
                self.assertEqual(command["durability"], "read_only", name)

    def test_loopback_bytes_and_half_close_share_bulk_and_the_abort_stays_control(self) -> None:
        commands = live()["commands"]
        self.assertEqual(set(ASSIGN.BULK_STREAM_WRITES), {"loopback-data", "loopback-shutdown"})
        self.assertEqual(
            {commands[name]["priority"] for name in ASSIGN.BULK_STREAM_WRITES}, {"bulk"}
        )
        # The close frees the slot the open takes, so neither is bulk.
        self.assertEqual(ASSIGN.RELEASES_SLOT, {"loopback-close": "loopback-open"})
        for name in ("loopback-open", "loopback-close"):
            self.assertEqual(commands[name]["priority"], "control", name)
        events = live()["events"]
        for name in ("loopback-data", "loopback-eof"):
            self.assertEqual(events[name]["priority"], "bulk", name)
        # An error close is a stream terminal on the control FIFO
        # (server/loopback_forward.rs ForwardStream::fail).
        for name in ("loopback-credit", "loopback-closed"):
            self.assertEqual(events[name]["priority"], "control", name)

    def test_a_write_that_frees_a_slot_cannot_ride_bulk(self) -> None:
        bulk = (*ASSIGN.COMMAND_PRIORITY["bulk"], "loopback-close")
        with (
            unittest.mock.patch.dict(ASSIGN.COMMAND_PRIORITY, {"bulk": bulk}),
            unittest.mock.patch.dict(ASSIGN.BULK_STREAM_WRITES, {"loopback-close": "fixture"}),
        ):
            with self.assertRaisesRegex(ASSIGN.AssignError, "RELEASES_SLOT: 'loopback-close'"):
                ASSIGN.Assigner(live()).check_tables()
        document = live()
        document["commands"]["loopback-close"]["priority"] = "bulk"
        with self.assertRaisesRegex(ASSIGN.AssignError, "RELEASES_SLOT: 'loopback-close'"):
            ASSIGN.Assigner(document).check_tables()

    def test_raw_swift_lines_count_as_macos_commands(self) -> None:
        names = ASSIGN.swift_line_commands()
        self.assertTrue(
            {"loopback-data", "loopback-credit", "loopback-shutdown", "loopback-close"} <= names,
            names,
        )
        commands = live()["commands"]
        for name in ("loopback-data", "loopback-close"):
            self.assertIn("macos", commands[name]["clients"], name)

    def test_typed_swift_command_names_count_as_macos_commands(self) -> None:
        """Request types migrated to `static let commandName: DaemonCommandName` may not reach swift_request_type_names
        and still name macos commands; without them nearly every command loses `macos`."""

        names = ASSIGN.swift_typed_commands()
        self.assertTrue({"chief-inspect", "machine-listening-tcp"} <= names, sorted(names)[:20])
        commands = live()["commands"]
        for name in ("chief-inspect", "machine-listening-tcp"):
            self.assertIn("macos", commands[name]["clients"], name)

    def test_independent_commands_are_daemon_queries_or_local_probes(self) -> None:
        """A Cloud, Create or Topology command needs state its connection set before it."""

        classes = daemon_method_classes()
        for name, command in live()["commands"].items():
            if command.get("ordering") == "independent":
                self.assertIn(classes.get(name), {"Query", "Other"}, name)


class HandlerFactTests(unittest.TestCase):
    """Commands whose daemon handler changes state are never read_only or independent.

    Each row names the line of the handler that changes state, so the test
    fails when the handler stops doing it and the attribute should be reviewed.
    """

    WRITERS = (
        ("cloud-selfhost-info", "../../cmux-tui-cloud-conversations/src/service.rs",
         "current.account = Some(user);"),
        ("browser-host-provider", "browser_host.rs", "let running = start(this, &binary, &config)?;"),
        ("snapshot-request", "server/terminal_snapshot.rs", "let admission = gate.request(now);"),
    )

    def test_state_changing_handlers_are_not_reads(self) -> None:
        commands = live()["commands"]
        for name, path, evidence in self.WRITERS:
            with self.subTest(name=name):
                self.assertIn(evidence, (CORE / path).read_text())
                self.assertNotEqual(commands[name]["durability"], "read_only")
                self.assertNotEqual(commands[name].get("ordering"), "independent")


class AgentMachineFilesScriptsTests(unittest.TestCase):
    """p05-ipc-019's commands: fs reads, chat move records, CLI senders, script-log."""

    def test_fs_reads_are_bulk_or_control_and_keep_call_order(self) -> None:
        commands = live()["commands"]
        self.assertEqual(commands["fs.read"]["priority"], "bulk")
        self.assertEqual(commands["agent-transfer-read"]["priority"], "bulk")
        self.assertEqual(commands["fs.stat"]["priority"], "control")
        # A read after this connection's own write must see it.
        for name in ("fs.read", "fs.stat", "agent-transfer-read"):
            self.assertNotEqual(commands[name].get("ordering"), "independent", name)
        # A later control rename or finish must not pass the bytes it names.
        for name in ("fs.write", "agent-transfer-write"):
            self.assertEqual(commands[name]["priority"], "control", name)

    def test_best_effort_move_records_do_not_reply_after_journal(self) -> None:
        commands = live()["commands"]
        for name, path, evidence in (
            ("agent-transfer-receive", "server/agent_transfer/askable.rs",
             'eprintln!("cmux-tui: chat move receive record not written: {error}");'),
            ("agent-transfer-finish", "server/agent_transfer/landed.rs",
             'eprintln!("cmux-tui: landed chat record not written: {error}");'),
        ):
            with self.subTest(name=name):
                self.assertIn(evidence, (CORE / path).read_text())
                self.assertEqual(commands[name]["durability"], "memory")

    def test_cli_call_helper_sends_are_cli_clients(self) -> None:
        commands = live()["commands"]
        self.assertEqual(ASSIGN.cli_call_helper_names(), set(ASSIGN.CLI_CALL_HELPER_SENDS))
        for name in ("fs.read", "agent-transfer-write", "access-request-answer"):
            self.assertIn("cli", commands[name]["clients"], name)
        for name in ("agent-update-plan", "agent-update-apply"):
            self.assertNotIn("cli", commands[name]["clients"], name)

    def test_a_cli_call_helper_entry_its_file_no_longer_names_is_refused(self) -> None:
        sends = dict(ASSIGN.CLI_CALL_HELPER_SENDS)
        sends["agent-update-plan"] = "link/sync_cli/remote.rs"
        original = ASSIGN.CLI_CALL_HELPER_SENDS
        ASSIGN.CLI_CALL_HELPER_SENDS = sends
        try:
            with self.assertRaisesRegex(ASSIGN.AssignError, "no longer names 'agent-update-plan'"):
                ASSIGN.cli_call_helper_names()
        finally:
            ASSIGN.CLI_CALL_HELPER_SENDS = original

    def test_script_log_has_an_event_id_and_rides_control(self) -> None:
        document = live()
        event = document["events"]["script-log"]
        self.assertEqual(event["event_id"] >> 8, document["families"]["script-events"]["id"])
        self.assertEqual(event["priority"], "control")


class AssignmentTests(unittest.TestCase):
    def test_new_command_takes_next_ordinal_of_its_family_and_keeps_other_ids(self) -> None:
        document = live()
        before = {name: entry["method_id"] for name, entry in document["commands"].items()}
        document["commands"]["machine-probe"] = probe(document)
        result = ASSIGN.Assigner(document, NO_SOURCES).run()
        daemon = [mid for mid in before.values() if mid >> 8 == 0x01]
        self.assertEqual(result["commands"]["machine-probe"]["method_id"], max(daemon) + 1)
        self.assertEqual(result["families"]["daemon"]["next_ordinal"], (max(daemon) & 0xFF) + 2)
        self.assertEqual(result["commands"]["machine-probe"]["clients"], ["sdk"])
        self.assertEqual(result["commands"]["machine-probe"]["durability"], "read_only")
        for name, method_id in before.items():
            self.assertEqual(result["commands"][name]["method_id"], method_id, name)

    def test_removed_top_id_is_never_given_again(self) -> None:
        document = live()
        commands = document["commands"]
        top = max((name for name in commands if commands[name]["method_id"] >> 8 == 0x01),
                  key=lambda name: commands[name]["method_id"])
        removed = commands.pop(top)["method_id"]
        commands["machine-probe"] = probe(document)
        assigner = ASSIGN.Assigner(document, NO_SOURCES)
        table = assigner.families()
        assigner.wire_ids("commands", "method_id", table, ASSIGN.FAMILIES)
        self.assertEqual(assigner.document["commands"]["machine-probe"]["method_id"], removed + 1)
        self.assertEqual(table["daemon"]["next_ordinal"], (removed & 0xFF) + 2)

    def test_existing_id_and_priority_are_never_rewritten(self) -> None:
        document = live()
        document["commands"]["ping"]["method_id"] = 0x01F0
        document["commands"]["ping"]["priority"] = "bulk"
        document["commands"]["machine-probe"] = probe(document)
        result = ASSIGN.Assigner(document, NO_SOURCES).run()
        self.assertEqual(result["commands"]["ping"]["method_id"], 0x01F0)
        self.assertEqual(result["commands"]["ping"]["priority"], "bulk")
        self.assertEqual(result["commands"]["machine-probe"]["method_id"], 0x01F1)

    def test_assigns_in_file_order_inside_a_family(self) -> None:
        document = live()
        document["commands"]["machine-probe-b"] = probe(document)
        document["commands"]["machine-probe-a"] = probe(document)
        result = ASSIGN.Assigner(document, NO_SOURCES).run()["commands"]
        self.assertEqual(result["machine-probe-a"]["method_id"], result["machine-probe-b"]["method_id"] + 1)

    def test_stream_target_without_reason_becomes_stream_scoped(self) -> None:
        document = live()
        entry = copy.deepcopy(document["commands"]["read-screen"])
        for key in ASSIGN.COMMAND_KEY_ORDER:
            entry.pop(key, None)
        document["commands"]["url-open-probe"] = entry
        result = ASSIGN.Assigner(document, NO_SOURCES).run()["commands"]["url-open-probe"]
        self.assertIs(result["stream_scoped"], True)
        self.assertEqual(result["durability"], "memory")

    def test_name_without_a_family_is_refused(self) -> None:
        document = live()
        document["commands"]["unclassified-probe"] = probe(document)
        with self.assertRaisesRegex(ASSIGN.AssignError, "matches no family"):
            ASSIGN.Assigner(document, NO_SOURCES).run()

    def test_name_in_two_families_is_refused(self) -> None:
        document = live()
        document["commands"]["cloud-conversation-probe"] = probe(document)
        families = dict(ASSIGN.FAMILIES)
        families["conversations"] = (0x0F, "x", (*families["conversations"][2], "cloud-conversation-probe"))
        original = ASSIGN.FAMILIES
        ASSIGN.FAMILIES = families
        try:
            with self.assertRaisesRegex(ASSIGN.AssignError, "matches families"):
                ASSIGN.Assigner(document, NO_SOURCES).run()
        finally:
            ASSIGN.FAMILIES = original

    def test_family_renumber_is_refused(self) -> None:
        document = live()
        document["families"]["tabs"]["id"] = 0x30
        with self.assertRaisesRegex(ASSIGN.AssignError, "never renumbered"):
            ASSIGN.Assigner(document, NO_SOURCES).run()

    def test_stale_rule_is_refused(self) -> None:
        document = live()
        del document["commands"]["server-stats"]
        with self.assertRaisesRegex(ASSIGN.AssignError, "matches no schema name"):
            ASSIGN.Assigner(document, NO_SOURCES).run()

    def test_bulk_write_outside_the_reviewed_list_is_refused(self) -> None:
        document = live()
        bulk = (*ASSIGN.COMMAND_PRIORITY["bulk"], "set-ratio")
        with unittest.mock.patch.dict(ASSIGN.COMMAND_PRIORITY, {"bulk": bulk}):
            with self.assertRaisesRegex(ASSIGN.AssignError, "'set-ratio' is a write"):
                ASSIGN.Assigner(document, NO_SOURCES).run()

    def test_clients_follow_their_sources_on_every_run(self) -> None:
        document = live()
        document["commands"]["ping"]["clients"] = ["cli", "sdk"]
        document["commands"]["identify"]["clients"] = ["ios", "sdk"]
        sources = ASSIGN.Sources(
            macos=lambda: {"ping"}, cli=lambda: {"ping"}, ios=lambda: {"ping", "send"}, swift_spawning=set
        )
        assigner = ASSIGN.Assigner(document, sources)
        result = assigner.run()["commands"]
        self.assertEqual(result["ping"]["clients"], ["macos", "ios", "cli", "sdk"])
        self.assertEqual(result["send"]["clients"], ["ios", "sdk"])
        # `ios` follows the iOS client's table too: a hand-set one the table does not list goes.
        self.assertEqual(result["identify"]["clients"], ["sdk"])
        self.assertIn('commands.ping.clients: ["macos", "ios", "cli", "sdk"]', assigner.changes)

    def test_ios_table_name_missing_from_the_schema_is_refused(self) -> None:
        sources = ASSIGN.Sources(macos=set, cli=set, ios=lambda: {"ping", "phone-only"}, swift_spawning=set)
        with self.assertRaisesRegex(ASSIGN.AssignError, "names phone-only, which sdk-schema.json does not declare"):
            ASSIGN.Assigner(live(), sources).run()

    def test_spawns_terminal_follows_the_reviewed_list(self) -> None:
        document = live()
        del document["commands"]["run"]["spawns_terminal"]
        document["commands"]["ping"]["spawns_terminal"] = True
        result = ASSIGN.Assigner(document, NO_SOURCES).run()["commands"]
        self.assertIs(result["run"]["spawns_terminal"], True)
        self.assertNotIn("spawns_terminal", result["ping"])

    def test_swift_spawning_request_missing_from_the_list_is_refused(self) -> None:
        sources = ASSIGN.Sources(macos=set, cli=set, swift_spawning=lambda: {"new-tab", "rename-surface"})
        with self.assertRaisesRegex(ASSIGN.AssignError, "SPAWNS_TERMINAL lacks rename-surface"):
            ASSIGN.Assigner(live(), sources).run()


class SwiftSourceTests(unittest.TestCase):
    def test_ios_command_table_is_the_schema_ios_set(self) -> None:
        names = ASSIGN.ios_command_names()
        self.assertTrue({"identify", "send", "split", "browser-back", "set-terminal-idle-policy"} <= names)
        marked = {name for name, command in live()["commands"].items() if "ios" in command.get("clients", [])}
        self.assertEqual(names, marked)

    def test_ios_command_table_line_that_is_not_one_case_is_refused(self) -> None:
        table = "enum CmuxTUICommand: String {\n    case send\n    case back, forward\n}\n"
        with unittest.mock.patch.object(Path, "read_text", return_value=table):
            with self.assertRaisesRegex(ASSIGN.AssignError, r"one simple case per line: \['case back, forward'\]"):
                ASSIGN.ios_command_names()

    def test_ios_case_without_a_raw_value_is_its_name(self) -> None:
        table = 'enum CmuxTUICommand: String {\n    case send\n    case newTab = "new-tab"\n}\n'
        with unittest.mock.patch.object(Path, "read_text", return_value=table):
            self.assertEqual(ASSIGN.ios_command_names(), {"send", "new-tab"})

    def test_agent_session_call_sites_are_macos_names(self) -> None:
        names = ASSIGN.swift_call_site_names()
        commands = {name for name in live()["commands"] if name.startswith("agent-session-")}
        self.assertEqual(len(commands), 11)
        self.assertLessEqual(commands, names)
        for name in commands:
            self.assertIn("macos", live()["commands"][name]["clients"])

    def test_cli_typed_requests_keep_cli(self) -> None:
        # The CLI sends these through cmux_ipc::client request types, which exist only
        # while the schema lists `cli`; they have no "cmd" literal for cli_cmd_line_names.
        names = ASSIGN.cli_typed_request_names(live()["commands"])
        self.assertTrue({"identify", "reload-config", "server-stats", "shutdown-daemon"} <= names)
        for name in names:
            self.assertIn("cli", live()["commands"][name]["clients"], name)

    def test_cli_typed_request_type_names_follow_build_rs(self) -> None:
        self.assertEqual(ASSIGN._pascal("reload-config"), "ReloadConfig")
        self.assertEqual(ASSIGN._pascal("fs.stat"), "FsStat")

    def test_swift_spawning_requests_are_listed(self) -> None:
        spawning = ASSIGN.swift_spawning_commands()
        self.assertTrue({"new-tab", "split", "create-terminal"} <= spawning)
        self.assertLessEqual(spawning, set(ASSIGN.SPAWNS_TERMINAL))


if __name__ == "__main__":
    unittest.main()
