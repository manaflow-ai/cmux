"""Home composer conditions for the journeys (journeys/p0/scripted-newtab-keeps-person-keys.json).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

Conditions (inside `expect.all`; evidence kind app):
  composer_text TEXT     the shown Home composer's message box holds exactly TEXT, read from the app
                         (`debug.home.drive {action: field}`, Debug and bench builds, record only): never text
                         recognition of its light grey pixels, which missed it (v2.2.4-opt gate). An app without
                         that read (before cp/debug-home-composer-field) answers "action must be ..."; then the
                         condition reads the window's frame for TEXT and says so in its detail (`fallback`).
"""
D = None  # the driver module (install)


def install(driver):
    global D
    D = driver


def cond_composer_text(j, want, cache):
    try:
        read = j.app.rpc("debug.home.drive", {"action": "field"}) or {}
    except D.StepError as error:
        if "action must be" not in str(error):
            raise
        ok, detail = j.evaluate("frame_text", want, {})
        return ok, dict(detail if isinstance(detail, dict) else {"detail": detail},
                        fallback="this app has no debug.home.drive field read: the frame's text was read")
    return read.get("text") == want, {"text": read.get("text"), "focused": read.get("focused")}


CONDITIONS = {"composer_text": ("app", cond_composer_text)}
