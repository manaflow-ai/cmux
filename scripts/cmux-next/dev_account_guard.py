"""Account guard for scripts that drive a tagged cmux-next build (preflights,
dogfood, pairing): nothing writes until the app's `auth.status` names the
account the caller expects.

hmdm1 on cmux-lawrence-2 (2026-10-06) wrote to another person's staging
account: the tagged build signed in from that machine's own
~/.secrets/cmuxterm-dev.env. A script now names the account it may act as
(`--expected-account`, the laptop's profile email) and calls
`require_account` before its first write; any other signed-in account, or
none within the timeout, stops the run.

    import dev_account_guard
    dev_account_guard.require_account(rpc, expected)   # raises AccountGuardError

`launch_environment(profile, expected)` gives the variables a launcher sets
so the app signs in only that profile's account (CMUX_DEV_AUTH_PROFILE,
CMUX_DEV_AUTH_ACCOUNT).
"""
import time


class AccountGuardError(RuntimeError):
    """The app is signed in as another account, or not signed in in time."""


def verdict(status, expected):
    """One `auth.status` reply judged against `expected` (an email, or None
    for a run that must stay signed out): "ok", "wait" or "refuse"."""
    status = status or {}
    if status.get("restoring"):
        return "wait"
    email = status.get("email") or ((status.get("user") or {}).get("email"))
    signed_in = bool(status.get("signed_in"))
    if not expected:
        return "refuse" if signed_in else "ok"
    if not signed_in or not email:
        return "wait"
    return "ok" if email.lower() == expected.lower() else "refuse"


def require_account(rpc, expected, timeout=90.0, step=0.5, clock=time.monotonic, sleep=time.sleep):
    """Waits until `auth.status` names `expected`. Raises AccountGuardError at
    once for any other account, and after `timeout` for no account.
    `rpc(method, params)` returns the reply's result object."""
    deadline = clock() + timeout
    last = None
    while True:
        last = rpc("auth.status", {})
        state = verdict(last, expected)
        if state == "ok":
            return last
        if state == "refuse":
            raise AccountGuardError(f"signed in as {mask((last or {}).get('email'))}, expected {mask(expected) if expected else 'no account'}; "
                                    "stopping before any write")
        if clock() >= deadline:
            raise AccountGuardError(f"not signed in as {mask(expected)} within {timeout:.0f} s; stopping before any write")
        sleep(step)


def launch_environment(profile, expected):
    """The variables that make a tagged build sign in only `profile`'s account."""
    if profile not in ("personal", "agent"):
        raise ValueError("profile must be personal or agent")
    if not expected:
        raise ValueError("an expected account is required")
    return {"CMUX_DEV_AUTH_PROFILE": profile, "CMUX_DEV_AUTH_ACCOUNT": expected}


def mask(email):
    if not email or "@" not in email:
        return "nobody" if not email else "***"
    local, domain = email.split("@", 1)
    return f"{local[:1]}***@{domain}"
