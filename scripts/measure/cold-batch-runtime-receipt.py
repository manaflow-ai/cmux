#!/usr/bin/env python3
"""Check a sanitized private cold-batch capture, never an ordinary one-hour flush.

Input: an object with events (controller records, raw_event wrappers, and
acp_prompt_received records) and cold_log (timestamped daemon log lines).
Select one run by its binary record's timestamp and both receiver IDs explicitly;
failed setup attempts or another receiver must not supply its evidence.
Exit 0: PASS, 1: FAIL, 2: INCOMPLETE (including malformed/missing evidence).
This verifies daemon scheduling with a controlled ACP agent, not model quality,
token savings, or the person's installed app. It prints no raw prompts/config.
"""
from __future__ import annotations

import argparse
import datetime
import json
import re
from pathlib import Path

DETECTOR = "cold-batch-runtime-receipt"
LATENESS_MS = 15_000


class ReceiptError(Exception):
    def __init__(self, reason, status="INCOMPLETE"):
        self.reason, self.status = reason, status


def require(condition, reason, status="INCOMPLETE"):
    if not condition:
        raise ReceiptError(reason, status)


def text_of(row):
    return "\n".join(block.get("text", "") for block in row.get("prompt", []))


def at(row):
    return row["event"]["at"] if row.get("kind") == "raw_event" else row["at"]


def check(evidence, run_start_ms, session_id, acp_session_id, markers):
    """Return a small receipt; reject missing evidence without Python assert."""
    result = {"detector": DETECTOR, "scope": "private daemon / controlled ACP agent",
              "session_id": session_id, "run_start_ms": run_start_ms,
              "savings_claim": False}
    try:
        require(len(markers) == 2 and all(markers) and markers[0] != markers[1], "TWO_DISTINCT_MARKERS_REQUIRED")
        events = evidence["events"]
        binaries = [r for r in events if r.get("kind") == "binary"]
        selected = [r for r in binaries if r["at"] == run_start_ms]
        require(len(selected) == 1, "BINARY_RUN_NOT_UNIQUE")
        identity = selected[0]
        require(re.fullmatch(r"[0-9a-f]{40}", identity.get("source", "")) is not None
                and re.fullmatch(r"[0-9a-f]{64}", identity.get("sha256", "")) is not None
                and identity.get("version") and identity.get("merge_ancestor_exit") == 0,
                "BINARY_IDENTITY_OR_ANCESTRY_MISSING")
        result["binary"] = {k: identity[k] for k in ("source", "sha256", "version", "merge_ancestor_exit")}
        next_run = min((r["at"] for r in binaries if r["at"] > run_start_ms), default=float("inf"))
        rows = [r for r in events if run_start_ms <= at(r) < next_run]
        captures = [r["at"] for r in rows if r["kind"] == "capture_complete"]
        require(len(captures) <= 1, "AMBIGUOUS_CAPTURE_END")
        end = captures[0] if captures else max((at(r) for r in rows), default=run_start_ms)
        rows = [r for r in rows if at(r) <= end]
        require(not any(r["kind"] == "FAILED" for r in rows), "CAPTURE_FAILED")
        result["capture_complete_ms"] = captures[0] if captures else None
        raw = [r["event"] for r in rows if r["kind"] == "raw_event"
               and r["event"].get("sessionId") == session_id]
        prompts = [r for r in rows if r["kind"] == "acp_prompt_received"
                   and r.get("sessionId") == acp_session_id]
        # A usage event links the mux receiver to the ACP receiver. Matching text alone does not.
        usage = [r for r in raw if r["kind"] == "usage_update"
                 and r["msg"].get("params", {}).get("sessionId") == acp_session_id]
        require(usage, "RECEIVER_ID_LINK_MISSING")
        opens = []
        for line in evidence["cold_log"]:
            if "cold wake batch opened" not in line:
                continue
            receiver = re.search(r"\bsession=([^\s]+)", line)
            if not receiver or receiver[1] != session_id:
                continue
            stamp = datetime.datetime.fromisoformat(line.split()[0].replace("Z", "+00:00"))
            opened = int(stamp.timestamp() * 1000)
            if not run_start_ms <= opened <= end or opened >= next_run:
                continue
            window = re.search(r"\bwindow_ms=(\d+)", line)
            require(window is not None, "COLD_WINDOW_MISSING")
            opens.append((opened, int(window[1])))
        require(opens, "NO_COLD_BATCH_OPEN")
        require(len(opens) == 1, "BATCH_REOPENED", "FAIL")
        opened, window = opens[0]
        require(60_000 <= window <= 300_000, "COLD_WINDOW_OUT_OF_RANGE", "FAIL")
        due = opened + window
        result.update(batch_open_ms=opened, window_ms=window, original_due_ms=due)
        begins = [r["at"] for r in rows if r["kind"] == "restart_begin"]
        restarts = [r["at"] for r in rows if r["kind"] == "restart_complete"]
        require(len(begins) == len(restarts) == 1 and opened < begins[0] < restarts[0] < due,
                "NO_SINGLE_RESTART_BEFORE_ORIGINAL_DEADLINE")
        result["restart_complete_ms"] = restarts[0]
        compacts = [r for r in prompts if r["at"] >= opened and text_of(r) == "/compact"]
        require(not any(r["at"] >= begins[0] for r in compacts), "COMPACTION_AFTER_RESTART", "FAIL")
        require(len(compacts) == 1, "NO_SINGLE_COMPACT_REQUEST")
        starts = [r for r in raw if r["kind"] == "turn_started" and r["at"] >= opened
                  and r["msg"].get("prompt") == "/compact"
                  and r["msg"].get("promptId", "").startswith("cold-wake-compact-")]
        require(len(starts) == 1, "COMPACTION_TURN_NOT_IDENTIFIED")
        compact_ends = [r for r in raw if r["kind"] == "turn_end"
                        and r["msg"].get("turnId") == starts[0]["msg"]["turnId"]
                        and r["msg"].get("stopReason") == "end_turn"]
        require(len(compact_ends) == 1 and starts[0]["at"] <= compacts[0]["at"]
                <= compact_ends[0]["at"] < begins[0], "COMPACTION_NOT_COMPLETED_BEFORE_RESTART")
        require(any(starts[0]["at"] <= r["at"] < begins[0]
                    and 0 <= r["msg"]["params"]["update"].get("used", 20_000) < 20_000 for r in usage),
                "WARM_USAGE_BEFORE_RESTART_MISSING")
        result["compaction_complete_ms"] = compact_ends[0]["at"]
        inbox = [r for r in raw if r["kind"] == "inbox"]
        require(len(inbox) == 2, "NOT_EXACTLY_TWO_INBOX_MESSAGES")
        for marker in markers:
            matches = [r for r in inbox if r["msg"].get("text") == marker]
            require(len(matches) == 1, "MARKER_ARRIVAL_MISSING")
            msg = matches[0]["msg"]
            provenance = msg.get("_meta", {}).get("provenance", {})
            require(msg.get("class") == "fyi" and provenance.get("gather") is True
                    and provenance.get("to") == session_id and "within" not in provenance,
                    "NON_TIMER_INBOX_TRIGGER", "FAIL")
        sends = [r for r in rows if r["kind"] == "cli" and r.get("args", [None])[0] == "send"]
        require(len(sends) == 2, "NOT_EXACTLY_TWO_SENDS")
        for send in sends:
            args = send["args"]
            require(send.get("code") == 0 and "--gather" in args
                    and "--class" in args and args[args.index("--class") + 1] == "fyi"
                    and not any(a.startswith(("--within", "--severity")) for a in args),
                    "NON_TIMER_CLI_TRIGGER", "FAIL")
        deliveries = [r for r in prompts if any(m in text_of(r) for m in markers)]
        # Check even failed captures: an unrelated wake invalidates timer-only
        # attribution, whether or not the FYIs reached the agent afterward.
        wake_bound = min((r["at"] for r in deliveries), default=end)
        require(not any(r["kind"] == "turn_started" and opened <= r["at"] <= wake_bound
                        and r["msg"].get("turnId") != starts[0]["msg"]["turnId"]
                        and not all(m in r["msg"].get("prompt", "") for m in markers) for r in raw),
                "OTHER_TURN_INVALIDATES_TIMER_ONLY", "FAIL")
        if not deliveries:
            require(captures and end >= due + LATENESS_MS, "CAPTURE_NOT_COMPLETE_THROUGH_DEADLINE")
            raise ReceiptError("NO_DELIVERY_BY_COLD_DEADLINE", "FAIL")
        require(len(deliveries) == 1, "NOT_EXACTLY_ONE_BATCHED_DELIVERY", "FAIL")
        delivery = deliveries[0]
        require(all(m in text_of(delivery) for m in markers), "MISSING_DELIVERED_MARKER", "FAIL")
        require(due - 1000 <= delivery["at"] <= due + LATENESS_MS,
                "DELIVERY_NOT_AT_ORIGINAL_DEADLINE", "FAIL")
        require(captures and end >= due + LATENESS_MS, "CAPTURE_NOT_COMPLETE_THROUGH_DEADLINE")
        result.update(status="PASS", delivery_ms=delivery["at"], deadline_lateness_ms=delivery["at"] - due)
    except ReceiptError as error:
        result.update(status=error.status, reason=error.reason)
    except (KeyError, TypeError, ValueError, IndexError, AttributeError):
        result.update(status="INCOMPLETE", reason="MALFORMED_EVIDENCE")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--run-start-ms", type=int, required=True, help="timestamp of the selected binary record")
    parser.add_argument("--session", required=True, help="mux session UUID")
    parser.add_argument("--acp-session", required=True, help="ACP receiver session UUID")
    parser.add_argument("--marker", action="append", required=True, help="repeat for the two exact FYI bodies")
    args = parser.parse_args()
    try:
        evidence = json.loads(args.evidence.read_text())
        result = check(evidence, args.run_start_ms, args.session, args.acp_session, args.marker)
    except (OSError, ValueError):
        result = {"status": "INCOMPLETE", "detector": DETECTOR, "reason": "EVIDENCE_UNREADABLE"}
    print(json.dumps(result, indent=2))
    return {"PASS": 0, "FAIL": 1, "INCOMPLETE": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
