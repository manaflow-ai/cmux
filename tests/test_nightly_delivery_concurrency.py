"""Nightly and Dev delivery must never cancel started work."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def delivery_workflows() -> list[Path]:
    paths = sorted(WORKFLOWS.glob("nightly*.yml"))
    paths += sorted(WORKFLOWS.glob("cmux-next-dev-daily*.yml"))
    return sorted(set(paths))


def test_delivery_workflows_never_cancel_in_progress_work() -> None:
    for path in delivery_workflows():
        text = path.read_text(encoding="utf-8")
        assert not re.search(r"(?m)^\s*cancel-in-progress:\s*true\s*$", text), path


# Shared nightly.yml job groups that may replace a pending job. None builds or signs: each is a
# promotion request (builds nothing; the newest request wins) or a feed writer whose replaced
# pending job is an older run's publish, which its order check would refuse after the newer one.
SHARED_NIGHTLY_GROUPS = {
    "promote-nightly-next": "nightly-next-promote",
    "await-release-surface-ack": "nightly-next-promote-ack",
    "publish-nightly": "release-publish-",
    "republish-nightly-deltas": "release-publish-",
    "publish-release-notes": "release-publish-",
    "publish-nightly-identity-legacy": "nightly-next-legacy-identity-publish",
}


# A group scoped to its run with nothing conditional: a fixed prefix and github.run_id, so no branch of
# an expression can fall back to a shared name (the old warm slot named github.run_id only in its fallback).
RUN_SCOPED = re.compile(
    r"\$\{\{ format\('[\w.-]*\{0\}', github\.run_id\) \}\}|[\w.-]*\$\{\{ github\.run_id \}\}")


def test_a_conditional_group_is_not_run_scoped() -> None:
    old_warm_slot = ("${{ github.ref == 'refs/heads/nightly-next' && 'nightly-next-build-app-warm' || "
                     "format('nightly-build-app-{0}', github.run_id) }}")
    assert not RUN_SCOPED.fullmatch(old_warm_slot)
    assert not RUN_SCOPED.fullmatch("nightly-${{ github.run_id }}-${{ github.ref_name }}")
    assert RUN_SCOPED.fullmatch("${{ format('nightly-build-app-{0}', github.run_id) }}")
    assert RUN_SCOPED.fullmatch("nightly-next-legacy-identity-${{ github.run_id }}")


def test_nightly_builds_and_signers_never_share_an_evicting_group() -> None:
    """A newer nightly tip builds and signs alongside an older one, never replacing it (2026-10-26).

    GitHub keeps one pending job per concurrency group and cancels the older pending one. A shared
    build slot (nightly-next-build-app-warm) and signing slot (nightly-next-legacy-identity) did
    that to waiting nightlies, and a holder stuck on a dead runner label held every newer tip.
    """
    import yaml

    document = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))
    top = document["concurrency"]["group"]
    # The nightly-next branch is the expression's first operand, so no other branch can win first.
    assert re.match(r"nightly-build-\$\{\{[^}]*\}\}-\$\{\{ github\.ref == 'refs/heads/nightly-next' && "
                    r"format\('run-\{0\}', github\.run_id\) \|\|", top), top
    for name, job in document["jobs"].items():
        concurrency = job.get("concurrency")
        if concurrency is None:
            continue
        group = concurrency if isinstance(concurrency, str) else str(concurrency.get("group", ""))
        if isinstance(concurrency, dict):
            assert concurrency.get("cancel-in-progress") is not True, name
        if RUN_SCOPED.fullmatch(group):
            continue
        allowed = SHARED_NIGHTLY_GROUPS.get(name)
        assert allowed and group.startswith(allowed), (
            f"nightly.yml {name} shares concurrency group {group!r}: a newer run would replace its pending "
            "job; scope it to github.run_id, or add it to SHARED_NIGHTLY_GROUPS if it builds nothing")


def test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups() -> None:
    tick = (WORKFLOWS / "nightly-next-tick.yml").read_text(encoding="utf-8")
    assert re.search(r'(?m)^\s+- cron: "7,37 \* \* \* \*"$', tick)
    assert "cancel-in-progress: false" in tick
    assert "group: nightly-next-tick-${{ github.run_id }}" in tick
    assert "coalesce:" in tick and "needs: coalesce" in tick
    assert "Number(a.id) - Number(b.id)" in tick
    assert "candidate[0] === currentOrder[0]" in tick
    dev = (WORKFLOWS / "cmux-next-dev-daily-dispatch.yml").read_text(encoding="utf-8")
    assert 'cron: "2-59/5 * * * *"' in dev or 'cron: "7,22,37,52 * * * *"' in dev
    assert "cancel-in-progress: false" in dev
    cmux_next = (WORKFLOWS / "cmux-next.yml").read_text(encoding="utf-8")
    assert "group: ${{ format('cmux-next-release-compile-{0}', github.run_id) }}" in cmux_next
    assert "needs.push-head-preflight.outputs.current == 'true'" in cmux_next


if __name__ == "__main__":
    test_delivery_workflows_never_cancel_in_progress_work()
    test_a_conditional_group_is_not_run_scoped()
    test_nightly_builds_and_signers_never_share_an_evicting_group()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()
    print("PASS: nightly and DEV delivery never cancel or replace waiting builds")
