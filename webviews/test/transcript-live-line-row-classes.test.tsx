// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// The running turn's line right under a step row is one more line of the run: model.ts isLiveStep
// marks it MARK_STEP in the layout (#31745). Its row classes say the same, so the DOM and the layout
// agree (#31769): the live line joins the step above it and the step row after it, and that row
// joins the live line.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { isLiveStep, PENDING_MESSAGES, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ACTIVITY_LINE, THINKING, WORKING } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";

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
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const Row = ({ row: item }: { row: AcpmuxRow }) => <div>{item.text}</div>;

const classesOf = async (rows: AcpmuxRow[]) => {
  const registry = Object.fromEntries(rows.map((item) => [item.kind, Row])) as never;
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  try {
    await act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId="live-line-classes"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    // Read every row's classes before the root unmounts.
    const classes = new Map(
      rows.map((item) => {
        const node = host.querySelector<HTMLElement>(`[data-row-id="${item.id}"]`);
        return [
          item.id,
          node
            ? {
                after: node.classList.contains("acpmux-row--after-step"),
                before: node.classList.contains("acpmux-row--before-step"),
              }
            : undefined,
        ] as const;
      }),
    );
    return (id: string) => {
      const found = classes.get(id);
      expect(found).toBeTruthy();
      return found!;
    };
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
};

const run: AcpmuxRow = { id: "run", version: 1, at: 1, kind: "activity", text: "Ran 2 commands", items: [] };
const waiting: AcpmuxRow = {
  id: "waiting",
  version: 1,
  at: 1,
  kind: PENDING_MESSAGES,
  text: "2 messages from 2 sessions",
};

for (const kind of [THINKING, WORKING, ACTIVITY_LINE]) {
  test(`the ${kind} live line under a run joins it and the waiting group's head`, async () => {
    const live: AcpmuxRow = { id: "live", version: 1, at: 1, kind, below: true, text: "Sending message to lane" };
    // The layout's own reading of the live line: one more line of the run.
    expect(isLiveStep(live, run)).toBe(true);
    const at = await classesOf([run, live, waiting]);
    expect(at("run")).toEqual({ after: false, before: true });
    expect(at("live")).toEqual({ after: true, before: true });
    expect(at("waiting")).toEqual({ after: true, before: false });
  });
}

test("a live line under a prose reply is the footer's slot and joins nothing", async () => {
  const reply: AcpmuxRow = { id: "reply", version: 1, at: 1, kind: "assistant", text: "Briefs are out." };
  const live: AcpmuxRow = { id: "live", version: 1, at: 1, kind: THINKING, below: true, text: "Thinking" };
  expect(isLiveStep(live, reply)).toBe(false);
  const at = await classesOf([reply, live, waiting]);
  expect(at("live")).toEqual({ after: false, before: false });
  expect(at("waiting")).toEqual({ after: false, before: false });
});
