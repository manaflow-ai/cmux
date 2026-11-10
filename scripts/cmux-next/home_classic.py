"""Classic Home for the Home GUI checks (cx-h0kds).

The checks (home-api-live.py, home-empty-send.py, home-perf.py,
home-tab-split-preflight.py) drive classic Home: the `home-messages` page as a top page, through
home_page.py. Docked Home is the default since S5 (train 705b5d752d18): at launch the app moves the
window to the home workspace with the `home-channels` page in its left dock, which hides the classic
Home page the checks opened ("no Home conversation is shown", a blank snapshot). `CMUX_NEXT_CLASSIC_HOME=1`
at launch selects classic Home (HomeDock.classicAtLaunch). `require` stops a check at once, with the cause,
when the app does not run classic Home.
"""
import json
import time

# Launch environment for the tagged app: classic Home, read once at launch.
ENV = {"CMUX_NEXT_CLASSIC_HOME": "1"}


def require(rpc, timeout=120):
    """True when `debug.home` reports classic Home. Else prints why and returns False (the check must stop)."""
    deadline = time.time() + timeout
    report = None
    while time.time() < deadline:
        report = rpc("debug.home")
        if isinstance(report, dict) and "classic" in report:
            break
        if isinstance(report, dict) and "available" in report:
            break  # an app older than cx-h0kds answers without `classic`: stop now, not after the timeout
        time.sleep(0.25)  # test harness wait for the app's debug socket, not app code
    if not (isinstance(report, dict) and "classic" in report):
        print("FAIL classic Home: debug.home did not answer with `classic` (in %d s, or the app is older than cx-h0kds "
              "and cannot tell docked from classic Home): %s" % (timeout, json.dumps(report)[:300]), flush=True)
        return False
    if report.get("classic") is not True:
        print("FAIL classic Home is not active (debug.home classic=%s). These checks drive the classic Home "
              "page; docked Home hides it. Launch the tagged app with CMUX_NEXT_CLASSIC_HOME=1."
              % json.dumps(report.get("classic")), flush=True)
        return False
    print("ok   classic Home is active (CMUX_NEXT_CLASSIC_HOME=1)", flush=True)
    return True
