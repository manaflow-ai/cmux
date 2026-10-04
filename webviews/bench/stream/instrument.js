// Streaming instrumentation, injected before any page script (Playwright addInitScript).
// Records, on the page's own clock:
//   ws:      every WebSocket message: [t, bytes, kind, textDeltaChars]
//   frames:  every requestAnimationFrame timestamp
//   paints:  per frame, chars of the streaming assistant row's text that changed since the last frame
//   blocks:  per frame, whether an earlier (non-last) markdown block of the streaming row moved or resized
//   pin:     per frame, distance from the scroller's end while the reader is meant to be pinned
//   anchor:  per frame, drift of the element the reader scrolled to (scrolled-up phase)
//   code:    code-block rebuilds (Pierre replaced its line nodes) and empty-code frames
//   shifts / longtasks: PerformanceObserver entries where the engine supports them
// Everything is read back as window.__stream.
(() => {
  const m = {
    ws: [],
    updates: [],
    react: [],
    frames: [],
    paints: [],
    blocks: { frames: 0, moved: 0, maxMovePx: 0, shrinks: 0, maxShrinkPx: 0 },
    edge: [],
    pin: [],
    anchor: [],
    code: { rebuilds: 0, emptyFrames: 0, frames: 0, samples: [] },
    shifts: [],
    longtasks: [],
    phase: "idle",
    anchorEl: null,
    anchorTop: 0,
  };
  window.__stream = m;

  const NativeWS = window.WebSocket;
  if (NativeWS) {
    window.WebSocket = class extends NativeWS {
      constructor(...args) {
        super(...args);
        this.addEventListener("message", (event) => {
          const t = performance.now();
          const data = String(event.data);
          let kind;
          let delta = -1;
          let update;
          if (data.includes('"_acpmux/event"')) {
            try {
              const message = JSON.parse(data);
              kind = message.params?.kind;
              update = message.params?.msg?.params?.update;
              const text = update?.content?.text;
              if (typeof text === "string") delta = text.length;
              else update = undefined;
            } catch {}
          }
          m.ws.push([t, data.length, kind, delta]);
          if (update) m.updates.push([t, update]);
        });
      }
    };
  }

  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) if (!entry.hadRecentInput) m.shifts.push([entry.startTime, entry.value]);
    }).observe({ type: "layout-shift", buffered: true });
  } catch {}
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) m.longtasks.push([entry.startTime, entry.duration]);
    }).observe({ type: "longtask", buffered: true });
  } catch {}

  let lastLen = 0;
  let lastRow = null;
  let lastBlocks = [];
  const lineIds = new WeakMap();
  let nextLineId = 1;
  const lastCodeLine = new Map();

  const streamingRow = () => {
    const rows = document.querySelectorAll(".acpmux-row.acpmux-assistant");
    return rows.length ? rows[rows.length - 1] : null;
  };

  const tick = (now) => {
    m.frames.push(now);
    if (m.phase !== "idle") {
      const row = streamingRow();
      if (row) {
        const md = row.querySelector(".cv-md") ?? row;
        const len = md.textContent.length;
        if (row !== lastRow) {
          lastRow = row;
          lastLen = 0;
          lastBlocks = [];
        }
        m.paints.push([now, len - lastLen]);
        lastLen = len;
        // Earlier blocks must not move inside the row as the last one grows.
        const rowTop = row.getBoundingClientRect().top;
        const blocks = [...md.children].map((child) => {
          const rect = child.getBoundingClientRect();
          return [rect.top - rowTop, rect.height];
        });
        m.blocks.frames += 1;
        for (let index = 0; index < Math.min(blocks.length, lastBlocks.length) - 1; index += 1) {
          const moved = Math.max(
            Math.abs(blocks[index][0] - lastBlocks[index][0]),
            Math.abs(blocks[index][1] - lastBlocks[index][1]),
          );
          if (moved > 0.5) {
            m.blocks.moved += 1;
            m.blocks.maxMovePx = Math.max(m.blocks.maxMovePx, moved);
            break;
          }
        }
        // The growing (last) block must never get shorter: that is a re-layout the reader sees.
        const lastIndex = blocks.length - 1;
        if (lastIndex >= 0 && lastBlocks.length === blocks.length) {
          const shrink = lastBlocks[lastIndex][1] - blocks[lastIndex][1];
          if (shrink > 0.5) {
            m.blocks.shrinks += 1;
            m.blocks.maxShrinkPx = Math.max(m.blocks.maxShrinkPx, shrink);
          }
        }
        lastBlocks = blocks;
        // Where the row's text sits in the viewport (transforms included): per-frame jumps of read text.
        m.edge.push([now, rowTop]);
        // Code blocks: Pierre renders into an open shadow root; a fresh first line node means a rebuild.
        for (const [index, host] of [...row.querySelectorAll("diffs-container")].entries()) {
          const lines = host.shadowRoot?.querySelectorAll("[data-line]") ?? [];
          m.code.frames += 1;
          if (lines.length === 0) m.code.emptyFrames += 1;
          const first = lines[0];
          if (first) {
            if (!lineIds.has(first)) lineIds.set(first, nextLineId++);
            const id = lineIds.get(first);
            const key = `${index}`;
            if (lastCodeLine.has(key) && lastCodeLine.get(key) !== id) m.code.rebuilds += 1;
            lastCodeLine.set(key, id);
          }
        }
      }
      const scroller = document.querySelector(".acpmux-scroll");
      if (scroller) {
        if (m.phase === "pinned") m.pin.push([now, scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop]);
        if (m.phase === "scrolled" && m.anchorEl?.isConnected)
          m.anchor.push([now, m.anchorEl.getBoundingClientRect().top - m.anchorTop]);
      }
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);

  /// Pins the anchor: the first element whose top is inside the scroller, after scrolling up `px`.
  window.__streamScrollUp = (px) => {
    const scroller = document.querySelector(".acpmux-scroll");
    if (!scroller) return false;
    scroller.scrollTop = Math.max(0, scroller.scrollTop - px);
    scroller.dispatchEvent(new Event("scroll"));
    return new Promise((resolve) =>
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          const viewTop = scroller.getBoundingClientRect().top;
          const candidates = scroller.querySelectorAll(".cv-md > *, .cv-user__bubble");
          for (const element of candidates) {
            const top = element.getBoundingClientRect().top;
            if (top >= viewTop) {
              m.anchorEl = element;
              m.anchorTop = top;
              m.phase = "scrolled";
              resolve(true);
              return;
            }
          }
          resolve(false);
        }),
      ),
    );
  };
})();
