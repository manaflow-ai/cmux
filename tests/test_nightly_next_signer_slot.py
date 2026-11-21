#!/usr/bin/env python3
"""signing_runner.py next-slot: which signer Mac a nightly-next loop run's nightly-next-one takes when two build at once.

With vars.NIGHTLY_NEXT_SIGNER_SLOTS 2 each signer Mac (ultra1, cmux15) is its own push slot, so a landing during a
31 min build starts building on the other Mac instead of waiting (2026-11-21: three push runs queued behind run
44907462015). The reads are fakes: the runs list per status and each run's jobs.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import nightly_next_signer_slot as slot  # noqa: E402
import signing_runner  # noqa: E402

REPO = "o/r"


def job(run: int, status: str = "in_progress", mac: str | None = None, runner: str = "", started: str = "",
        name: str = slot.ONE_JOB) -> dict:
    labels = [signing_runner.SIGNER_LABEL] + ([slot.MACS[mac]] if mac else [])
    return {"run_id": run, "name": name, "status": status, "labels": labels, "runner_name": runner,
            "started_at": started}


def reader(runs: dict[str, list[int]], jobs: dict[int, list[dict]], fail: str = ""):
    calls: list[str] = []

    def read(path: str) -> dict:
        calls.append(path)
        if fail and fail in path:
            raise slot.Unknown(f"GET {path}: HTTPError")
        page = int(path.rsplit("page=", 1)[1])
        if "/workflows/nightly.yml/runs?" in path:
            status = path.split("status=", 1)[1].split("&", 1)[0]
            return {"workflow_runs": [{"id": r} for r in runs.get(status, [])] if page == 1 else []}
        run = int(path.split("/runs/", 1)[1].split("/", 1)[0])
        return {"jobs": jobs.get(run, []) if page == 1 else []}
    read.calls = calls  # type: ignore[attr-defined]
    return read


def outputs(env: dict, read) -> dict[str, str]:
    with tempfile.NamedTemporaryFile("r+", suffix=".out") as out:
        assert slot.main({**env, "GITHUB_OUTPUT": out.name}, read) == 0
        return dict(line.split("=", 1) for line in Path(out.name).read_text().splitlines())


ENV = {"SLOTS": "2", "REPOSITORY": REPO, "RUN_ID": "100"}


class SignerSlotTests(unittest.TestCase):
    def test_off_unless_two_slots(self) -> None:
        for value in ("", "1", "3"):
            read = reader({}, {})
            self.assertEqual(outputs({**ENV, "SLOTS": value}, read), {"slot": "", "owned": ""})
            self.assertEqual(read.calls, [], "no read when the variable is not 2")

    def test_both_free_takes_ultra1(self) -> None:
        self.assertEqual(outputs(ENV, reader({}, {})),
                         {"slot": "ultra1", "owned": '["glaeda-trusted-next-signing","glaeda-runner-ultra1-glaeda"]'})

    def test_a_build_on_ultra1_sends_the_next_to_cmux15(self) -> None:
        read = reader({"in_progress": [90]}, {90: [job(90, mac="ultra1", started="2026-11-21T10:40:00Z"),
                                                   job(90, name="other", mac="cmux15")]})
        self.assertEqual(outputs(ENV, read)["owned"], '["glaeda-trusted-next-signing","glaeda-runner-cmux15-glaeda"]')

    def test_a_running_job_is_placed_by_its_runner_name_too(self) -> None:
        read = reader({"in_progress": [90]}, {90: [job(90, runner="cmux15-glaeda-1", started="2026-11-21T10:00:00Z")]})
        self.assertEqual(outputs(ENV, read)["slot"], "ultra1")

    def test_this_run_and_finished_jobs_hold_no_slot(self) -> None:
        read = reader({"in_progress": [100, 91]}, {100: [job(100, mac="ultra1", started="2026-11-21T10:59:00Z")], 91: [job(91, "completed", "ultra1")]})
        self.assertEqual(outputs(ENV, read)["slot"], "ultra1")

    def test_both_busy_takes_the_pending_slot_so_the_newest_head_builds_there_next(self) -> None:
        read = reader({"in_progress": [90, 91], "waiting": [92]},
                      {90: [job(90, mac="ultra1", started="2026-11-21T10:00:00Z")],
                       91: [job(91, mac="cmux15", started="2026-11-21T10:20:00Z")],
                       92: [job(92, "pending", mac="cmux15")]})
        self.assertEqual(outputs(ENV, read)["slot"], "cmux15")

    def test_both_building_takes_the_one_that_started_first(self) -> None:
        read = reader({"in_progress": [90, 91]},
                      {90: [job(90, mac="ultra1", started="2026-11-21T10:20:00Z")],
                       91: [job(91, mac="cmux15", started="2026-11-21T10:00:00Z")]})
        self.assertEqual(outputs(ENV, read)["slot"], "cmux15")

    def test_an_unpinned_waiting_job_keeps_the_shared_slot(self) -> None:
        read = reader({"in_progress": [90]}, {90: [job(90, "queued")]})
        self.assertEqual(outputs(ENV, read), {"slot": "", "owned": ""})

    def test_a_failed_read_keeps_the_shared_slot(self) -> None:
        read = reader({}, {}, fail="status=waiting")
        self.assertEqual(outputs(ENV, read), {"slot": "", "owned": ""})

    def test_too_many_pages_keeps_the_shared_slot(self) -> None:
        def read(path: str) -> dict:
            return {"workflow_runs": [{"id": 1}], "jobs": []}
        self.assertEqual(outputs(ENV, read), {"slot": "", "owned": ""})

    def test_owned_names_only_the_signer_label_and_one_runner(self) -> None:
        for mac, owned in slot.OWNED.items():
            labels = json.loads(owned)
            self.assertEqual(labels[0], signing_runner.SIGNER_LABEL)
            self.assertTrue(signing_runner.signing_route_label(labels[0]))
            self.assertEqual(labels[1], f"glaeda-runner-{mac}-glaeda")

    def test_signing_runner_dispatches_next_slot(self) -> None:
        with tempfile.NamedTemporaryFile("r+", suffix=".out") as out:
            env = {"SLOTS": "", "GITHUB_OUTPUT": out.name}
            self.assertEqual(signing_runner.main(env, ["next-slot"]), 0)
            self.assertEqual(Path(out.name).read_text(), "slot=\nowned=\n")


if __name__ == "__main__":
    unittest.main()
