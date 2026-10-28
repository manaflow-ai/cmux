"""browser-use driver for bench.py: JSON lines on stdin/stdout, no model, no API key.

Run with the browser-use venv's python and `-I`, from a directory that is not the venv:
  /tmp/cu-bench/browser-use/.venv/bin/python -I bu_driver.py CHROME_PATH

Ops follow what browser-use's Agent does per step: Tools actions (navigate, click, input, send_keys) through
the action registry, and get_browser_state_summary(include_screenshot=False) rendered with
dom_state.llm_representation() (the element list the model reads). Defaults stay as shipped (page-load waits
0.25 s minimum and 0.5 s network idle, 0.1 s between actions); they are part of what a user gets.
"""
import asyncio
import json
import sys
import time

CHROME = sys.argv[1]


def reply(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def matches(node, spec):
    if node.tag_name.lower() != spec["tag"]:
        return False
    attrs = node.attributes or {}
    for key, want in spec.get("attr", {}).items():
        have = attrs.get(key, "")
        if key == "class":
            if want not in have.split():
                return False
        elif have != want:
            return False
    if "text" in spec and node.get_all_children_text().strip() != spec["text"]:
        return False
    return True


async def main():
    from browser_use import BrowserProfile, BrowserSession, Tools

    session = None
    tools = Tools()
    selector_map = {}
    loop = asyncio.get_running_loop()
    reply({"ready": True})
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            break
        msg = json.loads(line)
        op = msg["op"]
        t0 = time.perf_counter()
        try:
            text = ""
            if op == "start":
                profile = BrowserProfile(headless=True, executable_path=CHROME, user_data_dir=None, keep_alive=False)
                session = BrowserSession(browser_profile=profile)
                await session.start()
            elif op == "goto":
                r = await tools.registry.execute_action("navigate", {"url": msg["arg"]}, browser_session=session)
                if getattr(r, "error", None):
                    raise RuntimeError(r.error)
            elif op == "state":
                state = await session.get_browser_state_summary(include_screenshot=False)
                selector_map = state.dom_state.selector_map
                text = f"url: {state.url}\ntitle: {state.title}\n" + state.dom_state.llm_representation()
            elif op in ("click", "type"):
                target = msg["target"]
                hits = [i for i, n in sorted(selector_map.items()) if matches(n, target["bu"])]
                nth = target.get("nth", 0)
                if len(hits) <= nth:
                    raise RuntimeError(f"no element for {target['bu']}")
                index = hits[nth]
                if op == "click":
                    r = await tools.registry.execute_action("click", {"index": index}, browser_session=session)
                else:
                    r = await tools.registry.execute_action("input", {"index": index, "text": target["text"]}, browser_session=session)
                    if not getattr(r, "error", None) and target.get("submit"):
                        r = await tools.registry.execute_action("send_keys", {"keys": "Enter"}, browser_session=session)
                if getattr(r, "error", None):
                    raise RuntimeError(r.error)
            elif op == "stop":
                if session:
                    await session.kill()
                reply({"ok": True})
                break
            reply({"ok": True, "text": text, "inner_ms": (time.perf_counter() - t0) * 1000})
        except Exception as e:
            reply({"ok": False, "error": f"{type(e).__name__}: {e}"})


asyncio.run(main())
