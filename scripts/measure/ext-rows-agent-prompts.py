"""Click the two command prompt examples in an isolated published NIGHTLY.

Registration alone is not a GUI receipt. Keep the accessible states and pictures
before selection and after the runtime toast / unsent composer insertion. All
input and capture uses Computer Use; a refusal ends the row with no fallback.

Run with cmux-ci run --class light --display --script scripts/measure/ext-rows-nightly.sh
--ref SHA --arg rows=agent_prompts --artifact .build/ext-rows-nightly/report.tgz
--timeout 600 --queue-timeout 900. The receipt names the downloaded NIGHTLY build;
the harness commit is not the app's commit. No app build or hot swap is performed.
"""
from __future__ import annotations

import base64
import json
import time

TITLE = "Stand-up: Copy my note"
INSERT = ("Review the changes on this branch: what could break, what is missing a test, "
          "and what you would rename.")


def fixture(marker):
    manifest = {
        "name": "Agent prompt readback", "description": "Palette and slash command examples.",
        "runtime": {"main": "main.js"}, "catalog": "catalog.json", "cli": {"name": "standup"},
        "implements": {"cmux.composer.command/1": {"options": {"commands": [
            {"name": "review", "description": "Review my changes", "insert": INSERT}]}}},
    }
    operation = {
        "name": "local.customize.note", "owner": "app:local/customize",
        "class": "read", "risk": "read", "idempotency": "forbidden",
        "docs": "Builds a stand-up note, shows it in a toast and returns it.",
        "since": "0.1.0", "export": "note",
        "input": {"type": "object", "additionalProperties": False,
                  "properties": {"done": {"type": "array", "items": {"type": "string"}}}},
        "output": {"type": "object", "properties": {"note": {"type": "string"}}},
        "cli": {"path": "note"}, "mcp": {"expose": "default"}, "palette": {"title": TITLE},
    }
    runtime = ("async function note(args, {cmux}) {\n"
               f" const note = (args.done ?? [{json.dumps(marker)}]).join('\\n');\n"
               " await cmux.toast({title: note, tone: 'success'});\n"
               " console.log('agent-prompt-note ' + note);\n"
               " return {note};\n}\n"
               "globalThis.__cmuxAppExports = {note};\n")
    return manifest, {"catalog.json": json.dumps({"family": "local.customize", "operations": [operation]}),
                      "main.js": runtime}


def run(ctx, core):
    if not ctx.app or not ctx.control or not ctx.pid_file:
        return {"checks": {"gui_available": False}, "error": "Requires an isolated NIGHTLY GUI"}
    # Reuse the bounded MCP transport and accessibility traversal used by the Accounts readback.
    helper = core.load("agent_prompts_cu", core.ROOT / "scripts/measure/accounts-nightly-probe.py")
    folder = ctx.work / "agent-prompts"
    folder.mkdir(parents=True, exist_ok=True)
    result = {"checks": {}, "steps": [], "screenshots": [], "submitted": False}
    marker = f"Stand-up verified {ctx.token}"
    manifest, files = fixture(marker)
    install = core.install_customize(ctx, manifest, files)
    result["install"] = install
    result["checks"]["installed"] = install["installed"]
    if not install["installed"]:
        return result
    pid = int(ctx.pid_file.read_text().strip())
    cu = None

    def wait(probe, description, timeout=20):
        deadline = time.monotonic() + timeout
        while True:
            value = probe()
            if value:
                return value
            if time.monotonic() >= deadline:
                raise RuntimeError("Timed out: " + description)
            time.sleep(0.5)

    def windows():
        body, _ = cu.call("list_windows")
        own = [w for w in body.get("windows", []) if w.get("pid") == pid]
        if any(w.get("denied") for w in own):
            raise RuntimeError("Computer Use denied the isolated app")
        return [w["window_id"] for w in own if w.get("on_screen") and not w.get("minimized")]

    def scoped(window):
        if window not in windows():
            raise RuntimeError("Window no longer belongs to the isolated app PID")

    def nodes(window):
        scoped(window)
        body, _ = cu.call("get_ui_tree", window_id=window, format="json", max_nodes=5000)
        (folder / f"tree-{len(result['steps'])}.json").write_text(json.dumps(body, indent=2))
        if body.get("truncated"):
            raise RuntimeError("Truncated accessibility tree")
        return list(helper.flatten(body.get("root", {})))

    def find(predicate):
        found = [(w, n) for w in windows() for n in nodes(w)
                 if n.get("_visible", True) and not n.get("disabled") and predicate(n)]
        if len(found) > 1:
            raise RuntimeError("Ambiguous accessible control")
        return found[0] if found else None

    def click(target, label):
        window, node = target
        scoped(window)
        cu.call("click", window_id=window, element_id=node["id"], observe=False)
        result["steps"].append({"click": label, "window": window, "element": node["id"]})

    def shot(window, name):
        scoped(window)
        _, content = cu.call("screenshot", window_id=window, force=True)
        images = [c for c in content if c.get("type") == "image"]
        if len(images) != 1:
            raise RuntimeError("Computer Use screenshot returned no unique image")
        suffix = {"image/png": ".png", "image/jpeg": ".jpg"}.get(images[0].get("mimeType"))
        if not suffix:
            raise RuntimeError("Unsupported screenshot format")
        path = folder / (name + suffix)
        path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
        result["screenshots"].append(str(path))

    try:
        cu = helper.ComputerUse()
        own = wait(windows, "isolated app window")
        if len(own) != 1:
            raise RuntimeError("Expected one isolated app window before opening the palette")
        main = own[0]
        cu.call("press_key", window_id=main, keys="cmd+shift+p", observe=False)
        result["steps"].append({"key": "cmd+shift+p"})
        search = wait(lambda: find(lambda n: n.get("role") in {"search_field", "text_field"}),
                      "palette search field")
        click(search, "palette search")
        cu.call("type_text", window_id=search[0], text=TITLE, observe=False)
        item = wait(lambda: find(lambda n: n.get("name", "").strip() == TITLE and
                                n.get("role") in {"button", "option", "row", "list_item", "menu_item"}),
                    "stand-up palette item")
        shot(item[0], "palette-command")
        click(item, TITLE)
        toast = wait(lambda: find(lambda n: n.get("name", "").strip() == marker), "runtime toast", timeout=8)
        shot(toast[0], "standup-toast")
        result["checks"]["palette_toast_visible"] = True
        result["runtime_log"] = core.logs_with(ctx, "agent-prompt-note " + marker, wait=3)
        result["checks"]["palette_export_ran"] = bool(result["runtime_log"])
        opened = ctx.rpc("action.run", {"action": "palette.newAgentChat", "origin": "script"})
        result["new_chat"] = opened
        if isinstance(opened, dict) and opened.get("error"):
            raise RuntimeError("Could not open an isolated draft chat")
        prompt = wait(lambda: find(lambda n: n.get("role") in {"text_area", "text_field"} and
                                  n.get("name", "").strip() in {"Prompt", "Message", "Ask anything"}),
                      "empty chat composer")
        if prompt[1].get("value", "").strip():
            raise RuntimeError("Refusing to replace a non-empty composer")
        click(prompt, "empty composer")
        cu.call("type_text", window_id=prompt[0], text="/review", observe=False)
        result["steps"].append({"typed": "/review"})
        review = wait(lambda: find(lambda n: "Review my changes" in n.get("name", "") and
                                  n.get("role") in {"button", "option", "row", "list_item", "menu_item"}),
                      "review slash option")
        shot(review[0], "review-menu")
        click(review, "Review my changes")
        inserted = wait(lambda: find(lambda n: n.get("role") in {"text_area", "text_field"} and
                                    n.get("value", "").strip() == INSERT), "exact unsent draft")
        shot(inserted[0], "review-inserted-unsent")
        result["inserted_text"] = inserted[1]["value"]
        result["checks"]["exact_draft_inserted"] = True
        # There is deliberately no Return or Send action anywhere in this row.
        result["checks"]["draft_left_unsent"] = True
    except Exception as error:
        result["checks"]["gui_flow"] = False
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        if cu:
            cu.close()
        (folder / "receipt.json").write_text(json.dumps(result, indent=2))
    return result
