// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Dynamic scripts (`script=` in a stage or mock app URL): a variant's chat comes alive on a loop.
// A script is data: a list of beats, each the snapshot the pane receives next and how long it
// stays, made from the variant's own snapshot. The beats go through the pane's real `receive`,
// as the app's transport sends each snapshot, so every row is drawn by the shipped renderers.
// Timers stop while the page is hidden; no script runs unless the URL names one.
import type { AcpmuxRow, AcpmuxSnapshot } from "../../agent-session/acpmux/model";

export type Beat = { ms: number; snapshot: AcpmuxSnapshot };

const REPLY = `Here's what changed:

1. \`retry()\` wraps the request and retries 429 and 5xx responses three times.
2. The backoff starts at 200 ms and doubles, with jitter so parallel uploads spread out.
3. Two tests cover the 429 path and a request that never recovers.

\`\`\`ts
export async function retry<T>(run: () => Promise<T>, tries = 3): Promise<T> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      if (attempt >= tries || !isRetryable(error)) throw error;
      await sleep(200 * 2 ** (attempt - 1) * (0.5 + Math.random()));
    }
  }
}
\`\`\`

All 48 tests pass.`;

const TOOLS: [string, string][] = [
  ["Read src/net/fetch.ts", "read"],
  ["Search for fetchWithRetry in src", "search"],
  ["Edit src/net/retry.ts", "edit"],
  ["Edit test/retry.test.ts", "edit"],
  ["bun test", "execute"],
];

let serial = 0;
const at = () => Date.now();
const row = (kind: string, fields: Partial<AcpmuxRow>): AcpmuxRow => ({
  id: `script-${kind}-${serial}`,
  version: 1,
  at: at(),
  kind,
  ...fields,
});

function withRows(base: AcpmuxSnapshot, rows: AcpmuxRow[], working: boolean): AcpmuxSnapshot {
  return { ...base, rows: [...base.rows, ...rows], isWorking: working };
}

/** The reply arriving a few words at a time, then the turn's end. */
function streaming(base: AcpmuxSnapshot): Beat[] {
  const prompt = row("user", { text: "Can you add retries with backoff to the fetch helper?" });
  const words = REPLY.split(/(?<=\s)/);
  const beats: Beat[] = [{ ms: 600, snapshot: withRows(base, [prompt], true) }];
  for (let count = 3; count < words.length; count += 3) {
    const text = words.slice(0, count).join("");
    const reply = row("assistant", { id: `script-assistant-${serial}`, text, streaming: true, version: count });
    beats.push({ ms: 50, snapshot: withRows(base, [prompt, reply], true) });
  }
  const done = row("assistant", { id: `script-assistant-${serial}`, text: REPLY, version: words.length + 1 });
  const end = row("turnSummary", { durationMs: 14_000, toolCount: 0 });
  beats.push({ ms: 2500, snapshot: withRows(base, [prompt, done, end], false) });
  return beats;
}

/** Tool calls starting and finishing one after another, then the reply. */
function tools(base: AcpmuxSnapshot): Beat[] {
  const prompt = row("user", { text: "Add retries to the fetch helper and run the tests." });
  const beats: Beat[] = [{ ms: 500, snapshot: withRows(base, [prompt], true) }];
  const items: NonNullable<AcpmuxRow["items"]> = [];
  TOOLS.forEach(([title, kind], index) => {
    const tool = (status: string) => ({
      kind: "tool",
      text: title,
      tool: { id: `script-tool-${index}`, title, kind, status },
    });
    for (const status of ["in_progress", "completed"]) {
      items[index] = tool(status);
      const activity = row("activity", {
        id: `script-activity-${serial}`,
        items: [...items],
        toolCount: items.length,
        version: beats.length,
      });
      beats.push({ ms: status === "in_progress" ? 700 : 250, snapshot: withRows(base, [prompt, activity], true) });
    }
  });
  const activity = row("activity", {
    id: `script-activity-${serial}`,
    items: [...items],
    toolCount: items.length,
    version: beats.length,
  });
  const reply = row("assistant", { text: "Done: three tries with exponential backoff, and both new tests pass." });
  const end = row("turnSummary", { durationMs: 41_000, toolCount: items.length });
  beats.push({ ms: 2500, snapshot: withRows(base, [prompt, activity, reply, end], false) });
  return beats;
}

/** A turn that fails, with the error card the pane draws for it. */
function error(base: AcpmuxSnapshot): Beat[] {
  const prompt = row("user", { text: "Run the sidebar tests and fix what fails." });
  const reply = row("assistant", { text: "Running the sidebar tests first." });
  const failed = row("turnSummary", {
    status: "failed",
    durationMs: 9_000,
    error: "API Error: 529 Overloaded. The service is temporarily unavailable.",
  } as Partial<AcpmuxRow>);
  return [
    { ms: 600, snapshot: withRows(base, [prompt], true) },
    { ms: 1200, snapshot: withRows(base, [prompt, reply], true) },
    { ms: 3000, snapshot: withRows(base, [prompt, reply, failed], false) },
  ];
}

/** The scripts by name. Add one here; the URL then names it. */
export const SCRIPTS: Record<string, { title: string; beats: (base: AcpmuxSnapshot) => Beat[] }> = {
  streaming: { title: "A reply streams in, then the turn ends", beats: streaming },
  tools: { title: "Tool calls run one after another, then the reply", beats: tools },
  error: { title: "A turn fails with an error card", beats: error },
};

/**
 * Plays `name` over `base` through `receive`, on a loop with the base shown between rounds
 * (`loop=0` plays once and stays on the last beat). Returns a stop function.
 */
export function playScript(
  name: string,
  base: AcpmuxSnapshot,
  receive: (snapshot: AcpmuxSnapshot) => void,
  options: { loop: boolean },
): () => void {
  const script = SCRIPTS[name];
  if (!script) return () => {};
  let timer = 0;
  let stopped = false;
  let beats: Beat[] = [];
  let index = 0;
  const round = () => {
    serial += 1;
    beats = script.beats(structuredClone(base));
    index = 0;
  };
  const step = () => {
    timer = 0;
    if (stopped || document.hidden) return;
    if (index >= beats.length) {
      if (!options.loop) return;
      receive(structuredClone(base));
      round();
      timer = window.setTimeout(step, 1200);
      return;
    }
    const beat = beats[index++]!;
    receive(beat.snapshot);
    timer = window.setTimeout(step, beat.ms);
  };
  const onVisibility = () => {
    if (!document.hidden && timer === 0 && !stopped) step();
  };
  document.addEventListener("visibilitychange", onVisibility);
  round();
  timer = window.setTimeout(step, 400);
  return () => {
    stopped = true;
    window.clearTimeout(timer);
    document.removeEventListener("visibilitychange", onVisibility);
  };
}

/**
 * The `cpu=N` axis: main-thread contention, as on a machine N times slower or busy with other
 * work. Every 50 ms the page spins for (1 - 1/N) of it, so the page gets 1/N of the thread.
 * Stops while hidden. For a real throttle, a harness uses CDP `Emulation.setCPUThrottlingRate`.
 */
export function simulateCpuContention(factor: number): () => void {
  if (!(factor > 1)) return () => {};
  const busy = 50 * (1 - 1 / factor);
  const timer = window.setInterval(() => {
    if (document.hidden) return;
    const until = performance.now() + busy;
    while (performance.now() < until) {
      // Spin: the contention itself.
    }
  }, 50);
  return () => window.clearInterval(timer);
}

type Registry = { register(kind: string, renderer: (props: { row: AcpmuxRow }) => unknown): void };
type ReactLike = {
  createElement(type: string, props: Record<string, unknown> | null, ...children: unknown[]): unknown;
};

/** A custom element, as an extension's registry.js would define one: shadow DOM, its own style. */
function defineExampleCard(): void {
  if (customElements.get("cmux-example-card")) return;
  customElements.define(
    "cmux-example-card",
    class extends HTMLElement {
      connectedCallback() {
        if (this.shadowRoot) return;
        const shadow = this.attachShadow({ mode: "open" });
        shadow.innerHTML = `<style>
          :host { display: block; margin: 8px 0; padding: 10px 12px; border-radius: 10px;
            border: 1px solid color-mix(in srgb, currentColor 18%, transparent); font: inherit; }
          b { display: block; margin-bottom: 2px; }
        </style><b></b><span></span>`;
        shadow.querySelector("b")!.textContent = this.getAttribute("title") ?? "";
        shadow.querySelector("span")!.textContent = this.getAttribute("body") ?? "";
      }
    },
  );
}

/**
 * The `slot=` axis: an extension's renderer in the transcript, registered through the pane's real
 * registry (`window.cmuxAcpmuxRegistry`, what a user's registry.js calls) with rows of its kind.
 * Add one here; the URL then names it.
 */
export const SLOTS: Record<
  string,
  { title: string; kind: string; install(registry: Registry, react: ReactLike): void; rows: () => AcpmuxRow[] }
> = {
  "custom-element": {
    title: "A registry.js row renderer that draws a custom element",
    kind: "example.card",
    install(registry, react) {
      defineExampleCard();
      registry.register("example.card", ({ row }) =>
        react.createElement("cmux-example-card", { title: "Deploy preview", body: row.text ?? "" }),
      );
    },
    rows: () => [row("example.card", { id: "slot-example-card", text: "Preview is live at preview-1842.example.dev" })],
  },
};

/** Registers `name`'s renderer and returns `snapshot` with its rows; an unknown name changes nothing. */
export function applySlot(name: string | null, snapshot: AcpmuxSnapshot): AcpmuxSnapshot {
  const slot = name ? SLOTS[name] : undefined;
  const registry = (window as unknown as { cmuxAcpmuxRegistry?: Registry }).cmuxAcpmuxRegistry;
  const react = (window as unknown as { React?: ReactLike }).React;
  if (!slot || !registry || !react) return snapshot;
  slot.install(registry, react);
  return { ...snapshot, rows: [...snapshot.rows, ...slot.rows()] };
}
