"""Same-repository Mac pull request jobs on a label the CI controller grants (CI v2 step 9, cmuxterm-hq#16502).

Leo: "i thought we were only gonna label things cmux-linux and therefore likewise cmux-mac?" and
"putting our scheduler as the layer in front of github actions, then we're the ones deciding. and so
we can literally size per job ourselves." So no Mac pull request job picks a pool: each says plain
`cmux-mac` (the CI v2 lead's ruling, 2026-11-21). A Mac's asker sees free capacity, asks the
controller, and gets a one-job JIT runner carrying `cmux-mac` and the job's own labels, sized by the
scheduler. `cmux-size-<N>c` / `cmux-mem-<N>g` are a job's own size ask. The per-run label
`cmux-<run_id>-<run_attempt>-mac` (grant_label()) is only an opt-in, for a job that must have a
scheduler-sized machine of its own: no standing runner carries it.

The controller understands, beside `cmux-mac` or the per-run label: `cmux-size-<N>c`, `cmux-mem-<N>g`,
`xcode-<version>`, `cmux-signing`, and GitHub's self-hosted/macOS/ARM64. Any other label makes the job
ungrantable, so the grant label replaces a pool label (glaeda-*), never joins one. The Xcode a pool
label named (glaeda-std-xcode-26.6, or the lane's CMUX_CI_XCODE_APP_PR pin) rides along as
`xcode-26.6`.

The one switch is SWITCH_FILE (`{"on": false}`): merging this changes nothing until a one-line pull
request flips it, after an asker runs on every PR mini. Off, unreadable or malformed: no grant, and
every route is what it was.

grant_labels() is the runs-on, a JSON array (`["cmux-mac","xcode-26.6"]`), or "" for no
grant: the switch off, not a pull request, a pull request from another repository, or a repository
outside manaflow-ai (forks keep their own labels). simple_pool_picker.py emits it as `grant` for
ci.yml's and ci-macos.yml's jobs. The Mac workflows without a picker (auth-refresh-tests, billing,
cloud-*, iroh-v2, relay-tls, terminal-hang-diagnostics) keep their routes until the pull request that
flips the switch moves them onto `cmux-mac` inline; reverting that pull request is their off
switch. A per-run label in a re-run of failed jobs keeps the attempt that made it; the controller
grants a label naming an earlier attempt of the same run.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Iterable, Mapping

SWITCH_FILE = Path(__file__).with_name("mac-grants.json")
OWNER = "manaflow-ai"
# The plain Mac label every granted Mac pull request job says (cmuxterm-hq hq#16976 spells it the same).
MAC_LABEL = "cmux-mac"
# `cmux-<run_id>-<run_attempt>-mac`: the opt-in per-run label the controller grants.
GRANT_LABEL = re.compile(r"cmux-[0-9]+-[0-9]+-mac")
_XCODE = re.compile(r"(?:-xcode-|(?:^|/)Xcode_)(?P<version>[0-9]+(?:\.[0-9]+)*)(?:\.app)?(?:/|$)")


def switch_on(path: Path | str | None = None) -> bool:
    """Whether PATH (default SWITCH_FILE) says `"on": true`. A missing or malformed file is off."""
    try:
        data = json.loads(Path(SWITCH_FILE if path is None else path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and data.get("on") is True


def grant_label(run_id: str | int, attempt: str | int) -> str:
    return f"cmux-{run_id}-{attempt}-mac"


def is_grant_label(label: object) -> bool:
    return bool(GRANT_LABEL.fullmatch(str(label or "")))


def xcode_label(sources: Iterable[str | None]) -> str:
    """`xcode-<version>` from the first source naming one: a pool label (`...-xcode-26.6`), a JSON
    label array holding one, or an Xcode path (`/Applications/Xcode_26.6.app`); "" with none."""
    for source in sources:
        text = (source or "").strip()
        if not text:
            continue
        candidates = [text]
        if text.startswith("["):
            try:
                data = json.loads(text)
            except ValueError:
                data = []
            candidates = [str(item) for item in data] if isinstance(data, list) else []
        for candidate in candidates:
            match = _XCODE.search(candidate)
            if match:
                return f"xcode-{match.group('version')}"
    return ""


def same_repo_pr(env: Mapping[str, str]) -> bool:
    """A pull request from a branch of a manaflow-ai repository into that repository."""
    repo = (env.get("GITHUB_REPOSITORY") or "").strip()
    owner = (env.get("GITHUB_REPOSITORY_OWNER") or repo.partition("/")[0]).strip()
    return (env.get("EVENT_NAME") or env.get("GITHUB_EVENT_NAME") or "") == "pull_request" and owner == OWNER \
        and bool(repo) and (env.get("HEAD_REPO") or "").strip() == repo


def grant_labels(env: Mapping[str, str], xcode_sources: Iterable[str | None] = (),
                 path: Path | str | None = None) -> str:
    """This run's granted runs-on as a JSON array, or "" (see the module docstring)."""
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "1").strip()
    if not (run_id.isdigit() and attempt.isdigit() and same_repo_pr(env) and switch_on(path)):
        return ""
    labels = [MAC_LABEL]
    xcode = xcode_label(xcode_sources)
    if xcode:
        labels.append(xcode)
    return json.dumps(labels, separators=(",", ":"))

