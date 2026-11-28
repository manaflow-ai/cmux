// l10n-allow-file: benchmark pages, not shipped UI.
// The replay-under-load bench's `--painter` arms other than the real pane (bench-only; nothing here ships). Both paint
// the last N messages of the replayed session and count their own frame gaps into the same 0.1 ms buckets the pane's
// frame tally (frameTally.ts) sends, as `_acpmux/perf {op:"tally", painter}` on their own socket to the stand-in:
//   dom-floor  a minimal page whose main thread appends the messages as plain text nodes: the floor of any painter on
//              the renderer main thread.
//   worker     an OffscreenCanvas painted from a dedicated Worker that owns its own socket to the stand-in, lays the
//              text out and fillText()s it on the worker's own requestAnimationFrame. The bench loads it over the real
//              pane, so the renderer main thread stays as busy as the pane makes it: if the worker's frame p95 stays
//              low while main is at the pane's busy %, the visible frames no longer track the main thread.
// Each painter runs its frame loop for the whole run (the replay never stops working), as frameBudget.ts runs the
// pane's while the chat works.

/** The painter's frame loop, text layout and socket, as worker or page script (`self` is either). */
const PAINTER_CORE = String.raw`
const BUCKET_MS = 0.1, BUCKETS = 1000, FLUSH_MS = 5000, KEEP = 60;
function startPainter({ endpoint, session, painter, draw }) {
  const lines = [];
  let total = 0, dirty = false, counts = new Map(), last = 0, id = 1;
  const ws = new WebSocket(endpoint);
  const call = (method, params) => ws.send(JSON.stringify({ jsonrpc: "2.0", id: id++, method, params }));
  ws.onopen = () => { call("initialize", {}); call("_acpmux/attach", { sessionId: session }); };
  const texts = (value, out) => {
    if (typeof value === "string") { if (value.length > 3) out.push(value); }
    else if (Array.isArray(value)) for (const v of value) texts(v, out);
    else if (value && typeof value === "object") for (const k in value) texts(value[k], out);
    return out;
  };
  ws.onmessage = (raw) => {
    const message = JSON.parse(raw.data);
    if (message.method !== "_acpmux/event") return;
    const event = message.params;
    const text = (event.kind + ": " + texts(event.msg, []).join(" ")).slice(0, 600);
    lines.push(text);
    total += 1;
    if (lines.length > KEEP) lines.splice(0, lines.length - KEEP);
    dirty = true;
  };
  const frame = (now) => {
    if (last > 0) {
      const gap = now - last;
      if (gap > 0 && gap < 5000) {
        const index = Math.min(BUCKETS, Math.floor(gap / BUCKET_MS + 1e-9));
        counts.set(index, (counts.get(index) || 0) + 1);
      }
    }
    last = now;
    if (dirty) { dirty = false; draw(lines, total); }
    self.requestAnimationFrame(frame);
  };
  self.requestAnimationFrame(frame);
  setInterval(() => {
    if (counts.size === 0 || ws.readyState !== 1) return;
    const gaps = [...counts.entries()].sort((a, b) => a[0] - b[0]);
    counts = new Map();
    call("_acpmux/perf", { op: "tally", bucketMs: BUCKET_MS, gaps, painter });
  }, FLUSH_MS);
}
`;

/** The worker arm's script: paints into the OffscreenCanvas the page transfers to it. */
export const PAINTER_WORKER_JS = `${PAINTER_CORE}
self.onmessage = ({ data }) => {
  if (typeof self.requestAnimationFrame !== "function") throw new Error("no requestAnimationFrame in this worker");
  const { canvas, endpoint, session } = data;
  const ctx = canvas.getContext("2d");
  const LINE = 16, PAD = 8;
  ctx.font = "13px sans-serif";
  const draw = (lines) => {
    ctx.fillStyle = "#1e1e1e";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = "#e6e6e6";
    // Lay out from the bottom (the newest message) up, wrapping each message to the width, until the viewport fills.
    let y = canvas.height - PAD;
    for (let i = lines.length - 1; i >= 0 && y > 0; i--) {
      const words = lines[i].split(" ");
      const rows = [];
      let row = "";
      for (const word of words) {
        const next = row ? row + " " + word : word;
        if (ctx.measureText(next).width > canvas.width - 2 * PAD && row) { rows.push(row); row = word; }
        else row = next;
      }
      if (row) rows.push(row);
      for (let r = rows.length - 1; r >= 0 && y > 0; r--) { ctx.fillText(rows[r], PAD, y); y -= LINE; }
      y -= LINE / 2;
    }
  };
  startPainter({ endpoint, session, painter: "worker", draw });
};
`;

/** The dom-floor arm's page: `#endpoint=…&session=…` in its hash, as the pane's. */
export const DOM_FLOOR_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;background:#1e1e1e;color:#e6e6e6;font:13px sans-serif}
#painter{height:100vh;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end;padding:8px}
#painter p{margin:0 0 8px}
</style></head><body><div id="painter"></div><script>${PAINTER_CORE}
const hash = new URLSearchParams(location.hash.slice(1));
const root = document.getElementById("painter");
let shown = 0;
const draw = (lines, total) => {
  // Append what came since the last frame as text nodes; drop what scrolled past the kept window.
  const fresh = Math.min(lines.length, total - shown);
  for (const text of lines.slice(lines.length - fresh)) {
    const p = document.createElement("p");
    p.textContent = text;
    root.appendChild(p);
  }
  shown = total;
  while (root.childElementCount > KEEP) root.firstElementChild.remove();
};
startPainter({ endpoint: hash.get("endpoint"), session: hash.get("session"), painter: "dom-floor", draw });
</script></body></html>`;

/** The init script the worker arm adds to the real pane: an overlay canvas, transferred to the painter worker. */
export function workerOverlay(args: { endpoint: string; session: string }): void {
  const start = () => {
    const canvas = document.createElement("canvas");
    canvas.width = 900;
    canvas.height = 300;
    canvas.style.cssText =
      "position:fixed;left:0;bottom:0;width:900px;height:300px;pointer-events:none;z-index:2147483647";
    document.body.appendChild(canvas);
    const offscreen = canvas.transferControlToOffscreen();
    const worker = new Worker("/__painter-worker.js");
    worker.onerror = (e) => console.error(`painter worker: ${e.message}`);
    worker.postMessage({ canvas: offscreen, endpoint: args.endpoint, session: args.session }, [offscreen]);
  };
  if (document.body) start();
  else document.addEventListener("DOMContentLoaded", start, { once: true });
}
