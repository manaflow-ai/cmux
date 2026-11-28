"""Page-initiated downloads for downloads-live.py, served by its loopback fixture."""

import hashlib
import json
from pathlib import Path
import re
import threading

TEXT = b"cmux handoff synthetic attachment\n"
BLOCK = bytes(range(256)) * 1024
LARGE_BYTES = 64 << 20
large_progress_seen = threading.Event()
LARGE_SHA256 = "281e519df3077b557c6b03f5da83c4e8d397219259615dd7c3308f89cae8f2a6"


def serve(request, run):
    path = request.path.partition("?")[0]
    if path == "/download-links":
        body = f"""<!doctype html><title>Download links</title>
<a id="attachment" href="/attachment">Attachment</a>
<a id="blob" download="blob-{run}.txt">Blob</a>
<a id="data" download="data-{run}.txt">Data</a>
<a id="large" href="/large">Large attachment</a>
<input id="file" type="file">
<script>
const text = {json.dumps(TEXT.decode())};
blob.href = URL.createObjectURL(new Blob([text]));
data.href = 'data:text/plain;charset=utf-8,' + encodeURIComponent(text);
document.addEventListener('click', e => document.body.dataset.trusted = e.isTrusted && e.target.id);
document.querySelector('#file').onchange = async e => {{
  const f = e.target.files[0];
  document.body.dataset.upload = e.target.files.length === 1 && f.name === 'attachment-{run}.txt'
    && await f.text() === text ? 'match' : 'mismatch';
}};
</script>""".encode()
        mime = "text/html; charset=utf-8"
    else:
        body = TEXT if path == "/attachment" else BLOCK
        mime = "application/octet-stream"
    large = path == "/large"
    request.send_response(200)
    request.send_header("Content-Type", mime)
    request.send_header("Content-Length", str(LARGE_BYTES if large else len(body)))
    if path != "/download-links":
        name = f"large-{run}.bin" if large else f"attachment-{run}.txt"
        request.send_header("Content-Disposition", f'attachment; filename="{name}"')
    request.end_headers()
    if large:
        # Leave the transfer in progress until its byte count reaches the Downloads list.
        # A busy runner can then observe it without relying on hundreds of timed sleeps.
        request.wfile.write(BLOCK * 8)
        request.wfile.flush()
        large_progress_seen.wait(30)
        for _ in range(LARGE_BYTES // len(BLOCK) - 8):
            request.wfile.write(BLOCK)
    else:
        request.wfile.write(body)


def exercise(rpc, wait_for, check, origin, folder, run, written):
    url = origin + "/download-links"
    reply = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
    tab = next((t for t in reply.get("created", []) if isinstance(t, str) and t.startswith("tab_")), None)
    if not tab:
        return check(False, f"chromium: open download fixture ({reply})")

    def page(method, **params):
        return rpc("browser.page." + method, {"tab": tab, **params})

    def value(script):
        return page("eval", script=script).get("value")

    ready = ("location.href===" + json.dumps(url) + " && /Chrome\\//.test(navigator.userAgent)"
             + " && document.getElementById('blob')?.protocol==='blob:'")
    if not wait_for(lambda: value(ready), "chromium: download fixtures loaded"):
        return
    page("select_tab")
    for key in ("attachment", "blob", "data", "large"):
        name = f"{key}-{run}." + ("bin" if key == "large" else "txt")
        target = Path(folder, name)
        written.append(str(target))
        if key == "large":
            large_progress_seen.clear()
        point = value(f"""(() => {{
          const el=document.getElementById('{key}'); el.scrollIntoView({{block:'center'}});
          const r=el.getBoundingClientRect(), x=r.x+r.width/2, y=r.y+r.height/2;
          return document.elementFromPoint(x,y)===el ? {{x,y}} : null;
        }})()""")
        click = page("mouse", kind="click", button="left", **point) if point else {}
        if not click.get("native") or value("document.body.dataset.trusted") != key:
            check(False, f"chromium: trusted click on {key}")
            continue
        progress = None
        answered = False

        def outcome():
            nonlocal progress, answered
            rows = rpc("debug.downloads").get("downloads", [])
            row = next((r for r in rows if r.get("filename") == name), None)
            if row and row.get("status") != "inProgress":
                return row
            if row and 0 < row.get("received", 0) < LARGE_BYTES and row.get("total") == LARGE_BYTES:
                progress = row["received"]
                large_progress_seen.set()
            if not row and not answered:
                prompts = rpc("debug.browser.prompts", {"tab": tab}).get("prompts", [])
                if prompts:
                    if (len(prompts) != 1 or prompts[0].get("origin") != origin or value("location.href") != url
                            or not re.fullmatch(r"permission\((?:\w+\.)*automaticDownloads\)", prompts[0].get("kind", ""))):
                        return {"error": "unexpected prompt", "prompts": prompts}
                    answered = rpc("debug.browser.prompts", {"tab": tab, "respond": "allow"}).get("responded")
                    if not answered:
                        return {"error": "could not answer automaticDownloads"}
            return None

        row = wait_for(outcome, f"chromium: {key} download ends", 120 if key == "large" else 30)
        if not row:
            continue
        if row.get("status") != "finished" or Path(row.get("destination", "")).resolve() != target.resolve() or not target.is_file():
            check(False, f"chromium: {key} saved under its suggested name ({row})")
            continue
        digest = hashlib.sha256()
        with target.open("rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
        expected = LARGE_SHA256 if key == "large" else hashlib.sha256(TEXT).hexdigest()
        size = LARGE_BYTES if key == "large" else len(TEXT)
        check(target.stat().st_size == size and digest.hexdigest() == expected,
              f"chromium: {name} has the expected {size} bytes and SHA-256")
        if key == "large":
            check(progress is not None, f"chromium: {name} reported progress ({progress} of {size} bytes)")
        if key == "attachment":
            uploaded = page("upload", selector="#file", files=[str(target)], agent="Downloads")
            if "error" in uploaded:
                check(False, f"chromium: attach downloaded fixture ({uploaded})")
            else:
                state = wait_for(lambda: value("document.body.dataset.upload"), "chromium: file input changed")
                check(state == "match", f"chromium: uploaded file has the expected name and bytes ({state})")
