"""nightly.yml's cargo calls ride out a crates.io blip.

Why: docs/ci/nightly-workflow-notes/2026-11-28-cargo-net-retry.md (job 140875083765: cargo's default 3
retries all timed out on index.crates.io and failed the NEXT nightly).
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def top_env(text: str) -> str:
    m = re.search(r"^env:\n((?:[ #].*\n|\n)*)", text, re.M)
    assert m, "nightly.yml has no workflow-level env"
    return m.group(1)


def test_workflow_env_sets_cargo_network_resilience():
    env = top_env((ROOT / ".github/workflows/nightly.yml").read_text())
    assert 'CARGO_NET_RETRY: "10"' in env
    assert 'CARGO_HTTP_TIMEOUT: "120"' in env
    assert 'CARGO_HTTP_MULTIPLEXING: "false"' in env


def test_no_job_turns_retries_back_down():
    text = (ROOT / ".github/workflows/nightly.yml").read_text()
    for m in re.finditer(r"CARGO_NET_RETRY:\s*\"?(\d+)", text):
        assert int(m.group(1)) >= 10, f"a step lowers CARGO_NET_RETRY to {m.group(1)}"
