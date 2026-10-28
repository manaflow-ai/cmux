// l10n-allow-file: test fixture rows, not shipped UI.
// Each transcript row type, rendered by the real VirtualTranscript (App.tsx's row registry), pinned
// to the DOM it draws (audit P10). App.tsx held every row renderer in one 9,400-line file and kept
// regressing; this pins what each row type draws so moving a renderer out of App.tsx changes no
// row. A refactor has no red: this file passed on the base before the split and must pass after it.
// The rows are the gallery's (src/gallery/fixtures/transcriptRowTypes.ts, entry
// agent-pane.transcript-row-types), so the gallery's screenshots show the same states.
// The pins are test/fixtures/transcript-row-types.json (type: markup). A run without that file
// writes it, and so does `CMUX_UPDATE_ROW_TYPES=1 bun test test/transcript-row-types.test.tsx` after
// a change that is meant to change a row; each also prints it as one base64 line
// (ROW_TYPES_PINS=...), for a run on a remote box.
import { afterAll, beforeAll, expect, setSystemTime, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { JSDOM, VirtualConsole } from "jsdom";

const PINS = path.join(import.meta.dir, "fixtures/transcript-row-types.json");
/// A first run (no pin file) writes the pins, as a first snapshot run does.
const UPDATE = process.env.CMUX_UPDATE_ROW_TYPES === "1" || !fs.existsSync(PINS);

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout. A tall viewport mounts every row of these small conversations.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { GALLERY_NOW } = await import("../src/gallery/clock");
const { ROW_TYPE_ROWS, ROW_TYPES, ROW_TYPES_SESSION } = await import("../src/gallery/fixtures/transcriptRowTypes");

// Relative times ("12m", "Yesterday") read against the gallery's now, the same in every run.
beforeAll(() => setSystemTime(new Date(GALLERY_NOW)));
afterAll(() => {
  setSystemTime();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// The thread's rows as markup, one tag per line, so a changed row reads as a small diff. React's
/// `useId` ids count across every root the run made, so each reads as its order in the row (id-1, ...).
const markup = (node: Element) => {
  const ids = new Map<string, string>();
  return node.innerHTML
    .replace(/></g, ">\n<")
    .replace(/_r_[0-9a-z]+_/g, (id) => ids.get(id) ?? ids.set(id, `id-${ids.size + 1}`).get(id)!);
};

/// What the transcript draws for `type`'s rows.
async function drawn(type: string): Promise<string> {
  const container = dom.window.document.createElement("div");
  dom.window.document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(
        <VirtualTranscript
          rows={ROW_TYPE_ROWS[type]!}
          sessionId={ROW_TYPES_SESSION}
          onToggleActivity={() => {}}
          expanded={new Set()}
          showMinimap={false}
        />,
      );
      // One painted frame: the rows' first layout pass and its effects.
      await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
    });
    const thread = container.querySelector(".acpmux-thread");
    if (!thread) throw new Error(`${type}: no transcript thread`);
    return markup(thread);
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
}

const pins: Record<string, string> = UPDATE ? {} : JSON.parse(fs.readFileSync(PINS, "utf8"));
const written: Record<string, string> = {};

test("every row type has a pin", () => {
  expect(ROW_TYPES.length).toBeGreaterThan(30);
  if (!UPDATE) expect(Object.keys(pins).sort()).toEqual([...ROW_TYPES].sort());
});

for (const type of ROW_TYPES)
  test(`row type ${type} draws as pinned`, async () => {
    const html = await drawn(type);
    // A row draws its article even when its renderer draws nothing (a render call outside the app).
    expect(html).toContain("acpmux-row");
    if (UPDATE) written[type] = html;
    else expect(html).toBe(pins[type]!);
  });

test("the same rows draw the same markup twice", async () => {
  for (const type of ROW_TYPES) expect(await drawn(type)).toBe(UPDATE ? written[type]! : pins[type]!);
});

if (UPDATE)
  afterAll(() => {
    const text = `${JSON.stringify(written, null, 2)}\n`;
    fs.writeFileSync(PINS, text);
    console.log(`ROW_TYPES_PINS=${Buffer.from(text).toString("base64")}`);
  });
