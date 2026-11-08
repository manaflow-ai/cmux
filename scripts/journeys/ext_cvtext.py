"""CLOSE VARIANTS screen text (m58 C: duplicated or lost lines from the terminal text, not the film). Local kit only.

  cv_text {pane, film, tag}   the named pane's terminal screen text (cmux terminal screen read) to
                              <video>/<film>.text-<tag>.json (fetched with the movies)
"""
import json

D = None


def install(driver):
    global D
    D = driver


def step_cv_text(j, step):
    import ext_video
    import ext_window
    rec = ext_window.named(j, step["pane"])
    try:
        text = j.app.screen(rec["term"]).get("text") or ""
    except D.StepError as error:
        text, err = "", str(error)[:200]
    else:
        err = None
    path = ext_video._vdir(j) / f"{step['film']}.text-{step['tag']}.json"
    path.write_text(json.dumps({"pane": step["pane"], "term": rec["term"], "text": text, "error": err}))
    return {"file": path.name, "lines": text.count("\n") + 1 if text else 0, "error": err}


STEPS = {"cv_text": step_cv_text}
CONDITIONS = {}
