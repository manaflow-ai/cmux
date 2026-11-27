#!/usr/bin/env bash
# dev_account_guard.py: a script that drives a tagged build writes nothing
# until auth.status names the expected account (hmdm1, 2026-10-06: a
# preflight wrote as the account in another machine's ambient secrets file).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PYTHONPATH="$ROOT/scripts/cmux-next" python3 - <<'PY'
import dev_account_guard as g

def fake(replies):
    calls = []
    def rpc(method, params):
        calls.append(method)
        return replies[min(len(calls), len(replies)) - 1]
    return rpc, calls

me, other = {"signed_in": True, "email": "Me@X.ai"}, {"signed_in": True, "email": "other@gmail.com"}
signed_out, restoring = {"signed_in": False, "email": None}, {"signed_in": False, "restoring": True}

# The expected account (case aside) passes after restoring and signed-out replies.
rpc, calls = fake([restoring, signed_out, me])
assert g.require_account(rpc, "me@x.ai", timeout=5, sleep=lambda _: None)["email"] == "Me@X.ai"
assert calls == ["auth.status"] * 3

# Another account stops the run at once, and the message masks both emails.
rpc, calls = fake([other])
try:
    g.require_account(rpc, "me@x.ai", timeout=5, sleep=lambda _: None)
    raise SystemExit("another account was accepted")
except g.AccountGuardError as error:
    text = str(error)
    assert "o***@gmail.com" in text and "m***@x.ai" in text and "other@gmail.com" not in text, text
assert calls == ["auth.status"]

# Nobody signed in by the deadline stops the run.
now = [0.0]
rpc, _ = fake([signed_out])
try:
    g.require_account(rpc, "me@x.ai", timeout=2, clock=lambda: now[0], sleep=lambda s: now.__setitem__(0, now[0] + 1))
    raise SystemExit("a signed-out app was accepted")
except g.AccountGuardError:
    pass

# A run that expects no account refuses any signed-in one.
assert g.verdict(other, None) == "refuse" and g.verdict(signed_out, None) == "ok"
# The old app's shape (user.email) is read too.
assert g.verdict({"signed_in": True, "user": {"email": "me@x.ai"}}, "me@x.ai") == "ok"

# A launch names an explicit profile and the expected account; nothing else is accepted.
assert g.launch_environment("personal", "me@x.ai") == {"CMUX_DEV_AUTH_PROFILE": "personal", "CMUX_DEV_AUTH_ACCOUNT": "me@x.ai"}
for bad in [("", "me@x.ai"), ("personal", "")]:
    try:
        g.launch_environment(*bad)
        raise SystemExit(f"accepted {bad}")
    except ValueError:
        pass
print("dev-account-guard: ok")
PY
