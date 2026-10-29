"""Keep git from leaving a background writer in temporary fixture repositories.

git commit, fetch, and clone start `git maintenance run --auto --detach`,
which can outlive the command and still be writing into `.git` when a
TemporaryDirectory is removed ("Directory not empty: '.git'"). Importing this
module turns that off for every git child of the importing test process;
tests that build a git environment from scratch pass it through
`without_auto_maintenance`.
"""

from __future__ import annotations

import os
import sys
from collections.abc import MutableMapping

_KEY = "maintenance.auto"


def without_auto_maintenance(env: MutableMapping[str, str]) -> MutableMapping[str, str]:
    """Append maintenance.auto=false to env's GIT_CONFIG_* pairs, once."""
    count = int(env.get("GIT_CONFIG_COUNT") or 0)
    # Git uses the last entry for a key, so only a trailing opt-out is enough.
    last_value = None
    for index in range(count):
        if env.get(f"GIT_CONFIG_KEY_{index}") == _KEY:
            last_value = env.get(f"GIT_CONFIG_VALUE_{index}", "")
    if last_value is not None and last_value.strip().lower() in {"false", "no", "off", "0"}:
        return env
    env[f"GIT_CONFIG_KEY_{count}"] = _KEY
    env[f"GIT_CONFIG_VALUE_{count}"] = "false"
    env["GIT_CONFIG_COUNT"] = str(count + 1)
    return env


# The pinned lint tools (ast-grep is 54 MB) of this machine, as prepush-gate.tools_dir() finds them, read before a
# fixture sets HOME: a fixture's hook then finds them instead of downloading them again in every setUp.
_LINT_TOOLS = os.environ.get("CMUX_LINT_TOOLS_DIR") or str(
    os.path.join(os.path.expanduser("~"), "Library", "Caches", "cmux-lint-tools") if sys.platform == "darwin"
    else os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"),
                      "cmux-lint-tools"))


def with_lint_tools(env: MutableMapping[str, str]) -> MutableMapping[str, str]:
    """Point env's pinned-tool cache (CMUX_LINT_TOOLS_DIR) at this machine's, so an installed fixture hook copies
    or uses the cached, sha256-checked tools and never downloads them."""
    env["CMUX_LINT_TOOLS_DIR"] = _LINT_TOOLS
    return env


without_auto_maintenance(os.environ)
