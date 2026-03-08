#!/usr/bin/env python3
import os
import tempfile
import time

from cmux import cmux, cmuxError


def find_document_plan(snapshot: dict, panel_id: str) -> dict:
    desired = dict(snapshot.get("desired") or {})
    plan = dict(desired.get("documentExecutorPlan") or {})
    for record in list(plan.get("records") or []):
        if str(record.get("panelId") or "") == panel_id:
            return dict(record)
    raise cmuxError(f"document executor record not found: {panel_id}")


def wait_for(predicate, timeout_s: float = 10.0, interval_s: float = 0.25):
    deadline = time.time() + timeout_s
    last_error = None
    while time.time() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Exception as exc:  # noqa: BLE001
            last_error = exc
        time.sleep(interval_s)
    if last_error:
        raise last_error
    raise cmuxError("timed out waiting for condition")


def main() -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write("# residency\n\nhello\n")
        markdown_path = f.name

    try:
        with cmux() as c:
            original_workspace = c.current_workspace()
            result = c.markdown_open(markdown_path, workspace=original_workspace)
            panel_id = str(result.get("surface_id") or "")
            if not panel_id:
                raise cmuxError("markdown.open did not return surface_id")

        def load_plan():
            with cmux() as c:
                return find_document_plan(c.panel_lifecycle(), panel_id)

        plan = wait_for(
            lambda: (
                current
                if (current := load_plan()).get("targetResidency") == "visibleInActiveWindow"
                else None
            )
        )
        if plan.get("action") not in {"showInTree", "noop"}:
            raise cmuxError(f"unexpected document action: {plan.get('action')}")
        if plan.get("targetResidency") != "visibleInActiveWindow":
            raise cmuxError(f"unexpected target residency: {plan.get('targetResidency')}")

        print("PASS: markdown lifecycle residency distinguishes visible regenerable panels")
    finally:
        try:
            os.unlink(markdown_path)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
