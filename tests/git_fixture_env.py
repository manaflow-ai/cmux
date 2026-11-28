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


without_auto_maintenance(os.environ)
