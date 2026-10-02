"""Captures browser-use's DOM serialization, the element text its agent
prompt shows the model (`dom_state.llm_representation()`), for a step list.

stdin: {"url", "settle": seconds, "steps": [{"kind": "capture"} |
        {"kind": "eval", "js": "<expression>"} | {"kind": "noop"}]}
stdout (last line): {"version", "results": [{"text", "selectorMap"} | null]}

Headless Google Chrome on a throwaway profile. No LLM is involved.
"""
import asyncio
import importlib.metadata
import json
import os
import sys
import tempfile

from browser_use.browser import BrowserProfile, BrowserSession
from browser_use.dom.views import DEFAULT_INCLUDE_ATTRIBUTES

CHROME = os.environ.get("CMP_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"


async def main():
    job = json.load(sys.stdin)
    session = BrowserSession(
        browser_profile=BrowserProfile(
            executable_path=CHROME,
            headless=True,
            user_data_dir=tempfile.mkdtemp(prefix="cmp-bu-"),
            viewport={"width": 1280, "height": 800},
            window_size={"width": 1280, "height": 800},
            user_agent=UA,
            wait_for_network_idle_page_load_time=0.5,
            keep_alive=False,
        )
    )
    await session.start()
    results = []
    try:
        await session.navigate_to(job["url"])
        await asyncio.sleep(job.get("settle", 1.0))
        for step in job["steps"]:
            kind = step["kind"]
            if kind == "capture" and step.get("mode") != "interactive":
                state = await session.get_browser_state_summary(include_screenshot=False)
                dom = state.dom_state
                smap = {}
                for idx, node in (dom.selector_map or {}).items():
                    smap[str(idx)] = {"tag": node.tag_name, "text": node.get_meaningful_text_for_llm()[:80]}
                results.append({"text": dom.llm_representation(include_attributes=DEFAULT_INCLUDE_ATTRIBUTES), "selectorMap": smap})
            elif kind == "eval":
                page = await session.get_current_page()
                await page.evaluate("() => (%s)" % step["js"])
                await asyncio.sleep(0.25)
                results.append(None)
            else:
                results.append(None)
    finally:
        await session.kill()
    print(json.dumps({"version": importlib.metadata.version("browser-use"), "results": results}))


asyncio.run(main())
