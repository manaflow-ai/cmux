// In-page half of web_swap.sh (measure.mjs serves it into the agent pane of its copy). Every time is
// epoch milliseconds (performance.timeOrigin + performance.now()), the same clock measure.mjs reads, so a
// page time and a server time subtract; the server corrects a page time by the offset it measured with
// pings (min round trip). Reports go back over Vite's own HMR socket (import.meta.hot.send).
const now = () => performance.timeOrigin + performance.now();
const hot = import.meta.hot!;
const PROBE = "data-hot-reload-probe";
const FILE = "ComposerFoot.tsx";

type Update = { before?: number; after?: number };
const updates = new Map<string, Update>();
let lastUpdate: Update | null = null;
// Each Vite update that names the edited component (the client sends one per save).
hot.on("vite:beforeUpdate", (payload: { updates: { path: string; timestamp: number }[] }) => {
  hot.send("dev-loop:debug", { event: "beforeUpdate", payload });
  for (const update of payload.updates) {
    if (!update.path.endsWith(FILE)) continue;
    lastUpdate = { before: now() };
    updates.set(String(update.timestamp), lastUpdate);
  }
});
hot.on("vite:afterUpdate", (payload: { updates: { path: string; timestamp: number }[] }) => {
  hot.send("dev-loop:debug", { event: "afterUpdate", payload });
  for (const update of payload.updates) {
    const entry = updates.get(String(update.timestamp));
    if (entry && entry.after === undefined) entry.after = now();
  }
});

// The commit: the first DOM mutation that carries the round's probe value (a MutationObserver callback
// runs in the microtask after React's commit wrote it).
const waiting = new Map<string, (commit: number) => void>();
new MutationObserver((records) => {
  const at = now();
  for (const record of records) {
    const targets =
      record.type === "attributes" ? [record.target as Element] : [...record.addedNodes].filter((node) => node instanceof Element);
    for (const target of targets as Element[]) {
      const hits = [target, ...target.querySelectorAll(`[${PROBE}]`)];
      for (const hit of hits) {
        const value = hit.getAttribute?.(PROBE);
        if (value === null || value === undefined) continue;
        const done = waiting.get(value);
        if (done) {
          waiting.delete(value);
          done(at);
        }
      }
    }
  }
}).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: [PROBE] });

// The paint: the frame after the commit is drawn and handed to the compositor between the first animation
// frame callback after the commit and the next one; the second callback (the next vsync) is when that
// frame is on screen at the latest. paint = that second callback.
const nextPaint = () =>
  new Promise<{ raf: number; paint: number }>((resolve) =>
    requestAnimationFrame(() => {
      const raf = now();
      requestAnimationFrame(() => resolve({ raf, paint: now() }));
    }),
  );

const seen = (value: string, timeoutMs: number) =>
  new Promise<number | null>((resolve) => {
    if (document.querySelector(`[${PROBE}="${CSS.escape(value)}"]`)) return resolve(now());
    const timer = setTimeout(() => {
      waiting.delete(value);
      resolve(null);
    }, timeoutMs);
    waiting.set(value, (at) => {
      clearTimeout(timer);
      resolve(at);
    });
  });

// The module's own request: fetch start and response end of the newest ComposerFoot.tsx?t= request.
const moduleFetch = (since: number) => {
  const entries = performance
    .getEntriesByType("resource")
    .filter((entry) => entry.name.includes(FILE) && performance.timeOrigin + entry.startTime >= since - 1) as PerformanceResourceTiming[];
  const entry = entries.at(-1);
  if (!entry) return null;
  return {
    url: entry.name,
    fetchStart: performance.timeOrigin + entry.fetchStart,
    requestStart: performance.timeOrigin + entry.requestStart,
    responseStart: performance.timeOrigin + entry.responseStart,
    responseEnd: performance.timeOrigin + entry.responseEnd,
  };
};
performance.setResourceTimingBufferSize?.(100_000);

const reply = (event: string, data: object) => hot.send(`dev-loop:${event}`, data);

// A round: measure.mjs tells the page which probe value to wait for, then writes the file.
// Vite's client awaits each listener before it handles the next message (an update included): every
// handler here returns at once and does its waiting in a promise of its own.
hot.on("dev-loop:expect", ({ value, since }: { value: string; since: number }) => void expect(value, since));
const expect = async (value: string, since: number) => {
  lastUpdate = null;
  const commit = await seen(value, 15_000);
  if (commit === null) return reply("round", { value, error: "the edit never showed" });
  const frame = await nextPaint();
  reply("round", {
    value,
    commit,
    raf: frame.raf,
    paint: frame.paint,
    beforeUpdate: lastUpdate?.before ?? null,
    afterUpdate: lastUpdate?.after ?? null,
    fetch: moduleFetch(since),
  });
};

// Clock and socket: the server's send time comes back with the page's receive time.
hot.on("dev-loop:ping", ({ id, sent }: { id: number; sent: number }) => reply("pong", { id, sent, received: now() }));

// Frame interval: consecutive animation frame deltas.
hot.on("dev-loop:frames", ({ count }: { count: number }) => {
  const deltas: number[] = [];
  let last = 0;
  const step = (time: number) => {
    if (last) deltas.push(time - last);
    last = time;
    if (deltas.length < count) requestAnimationFrame(step);
    else reply("frames", { deltas });
  };
  requestAnimationFrame(step);
});

// The apply floor: import an already transformed copy of the edited component (served by measure.mjs; its
// $RefreshReg$ names the component's own file, so React Refresh takes it as the same component family),
// then the refresh plugin-react runs on an update, without its batching (its batch is taken and run at once),
// to the commit that writes the copy's probe value. The batch is the stock runtime's 16 ms `setTimeout`, or the
// `queueMicrotask` webviews/dev-server/refreshNow.ts puts in its place; whichever the runtime calls is taken.
type Runtime = {
  validateRefreshBoundaryAndEnqueueUpdate(id: string, prev: object, next: object): string | undefined;
};
hot.on("dev-loop:apply", ({ url, value, id }: { url: string; value: string; id: string }) => void apply(url, value, id));
const apply = async (url: string, value: string, id: string) => {
  try {
    const runtime = (await import(/* @vite-ignore */ "/@react-refresh")) as unknown as Runtime;
    const committed = seen(value, 10_000);
    const start = now();
    const next = (await import(/* @vite-ignore */ url)) as object;
    const imported = now();
    const setTimeoutBefore = window.setTimeout;
    const queueMicrotaskBefore = window.queueMicrotask;
    let batch: (() => unknown) | null = null;
    window.setTimeout = ((fn: () => unknown) => {
      batch = fn;
      return 0;
    }) as typeof window.setTimeout;
    window.queueMicrotask = (fn: () => unknown) => {
      batch = fn;
    };
    let refused: string | undefined;
    try {
      refused = runtime.validateRefreshBoundaryAndEnqueueUpdate(id, next, next);
    } finally {
      window.setTimeout = setTimeoutBefore;
      window.queueMicrotask = queueMicrotaskBefore;
    }
    if (refused || !batch) return reply("apply", { value, error: refused ?? "React Refresh queued no update" });
    await (batch as () => unknown)();
    const commit = await committed;
    if (commit === null) return reply("apply", { value, error: "the refreshed component never showed" });
    reply("apply", { value, start, imported, commit });
  } catch (error) {
    reply("apply", { value, error: String(error) });
  }
};

// The extra stylesheet edit: Vite swaps the <style> (or <link>) of bottomStack.css; the first head mutation
// after which the custom property reads the round's value is the commit, then the next frame.
hot.on("dev-loop:expect-css", ({ value }: { value: string }) => {
  const read = () => getComputedStyle(document.documentElement).getPropertyValue("--hot-reload-probe").trim() === value;
  let finished = false;
  const finish = async (commit: number | null) => {
    if (finished) return;
    finished = true;
    observer.disconnect();
    clearTimeout(timer);
    if (commit === null) return reply("css", { value, error: "the stylesheet edit never showed" });
    const frame = await nextPaint();
    reply("css", { value, commit, paint: frame.paint });
  };
  const observer = new MutationObserver(() => {
    if (read()) void finish(now());
  });
  observer.observe(document.head, { subtree: true, childList: true, characterData: true, attributes: true });
  // A <link> swap applies on its load, not on the mutation: check each frame too.
  const poll = () => {
    if (finished) return;
    if (read()) void finish(now());
    else requestAnimationFrame(poll);
  };
  requestAnimationFrame(poll);
  const timer = setTimeout(() => void finish(null), 15_000);
});

for (const event of ["vite:error", "vite:invalidate", "vite:beforeFullReload", "vite:ws:disconnect"])
  hot.on(event, (payload: unknown) => hot.send("dev-loop:debug", { event, payload }));
const ready = () => {
  const foot = document.querySelector(".acpmux-composer-foot");
  if (foot)
    reply("ready", {
      at: now(),
      href: location.href,
      modules: performance.getEntriesByType("resource").map((entry) => entry.name).filter((name) => name.includes(FILE)),
    });
  else setTimeout(ready, 100);
};
ready();
