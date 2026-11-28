// Hunk review from the chat's Sources popover (cx-ncc.47): Sources opens the turn's diff, where each
// change has Reject and Accept. A file's More menu now decides every change in it at once, and the
// rejected ones still go to the agent as one revert prompt.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  localStorage: dom.window.localStorage,
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
  // The file menu places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useState } = await import("react");
const { DiffPanel } = await import("../src/agent-session/acpmux/DiffPanel");
const { toolFiles } = await import("../src/agent-session/acpmux/diff");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Decision = "accepted" | "rejected" | "requested";

// Two files the turn changed: a.ts in two places far apart, b.ts in one.
const lines = (count: number, edit?: (line: number) => string | undefined) =>
  Array.from({ length: count }, (_, index) => edit?.(index + 1) ?? `line ${index + 1}`).join("\n");
const files = toolFiles([
  {
    id: "edit-a",
    kind: "edit",
    title: "Edit a.ts",
    status: "completed",
    diffs: [
      {
        path: "/repo/src/a.ts",
        oldText: lines(40),
        newText: lines(40, (line) => (line === 3 ? "changed three" : line === 35 ? "changed thirty-five" : undefined)),
      },
    ],
  },
  {
    id: "edit-b",
    kind: "edit",
    title: "Edit b.ts",
    status: "completed",
    diffs: [
      {
        path: "/repo/src/b.ts",
        oldText: lines(5),
        newText: lines(5, (line) => (line === 2 ? "changed two" : undefined)),
      },
    ],
  },
] as never);

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const menuItem = (label: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === label,
  );

test("a file's menu rejects or accepts every change in it, and the rejected ones go back as one revert", async () => {
  const sent: { keys: string[]; prompt: string }[] = [];
  function Review() {
    const [decisions, setDecisions] = useState<ReadonlyMap<string, Decision>>(new Map());
    const review = {
      decisions,
      decide: (key: string, decision: Decision | undefined) =>
        setDecisions((current) => {
          const next = new Map(current);
          if (decision) next.set(key, decision);
          else next.delete(key);
          return next;
        }),
      requestRevert: (keys: string[], prompt: string) => {
        sent.push({ keys, prompt });
        setDecisions((current) => new Map([...current, ...keys.map((key) => [key, "requested"] as const)]));
      },
    };
    return <DiffPanel files={files} reviewFiles={files} review={review} onClose={() => {}} />;
  }
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(<Review />));
  await settle();
  const decisionsOf = (name: string) =>
    [...container.querySelectorAll(".acpmux-diff-file")]
      .filter((block) => block.querySelector(".acpmux-fh-name")?.textContent?.includes(name))
      .flatMap((block) => [...block.querySelectorAll(".acpmux-hunk-actions")])
      .map((actions) => actions.querySelector("output")?.textContent ?? "undecided");
  const fromMenu = async (name: string, label: string) => {
    await act(async () =>
      container.querySelector<HTMLButtonElement>(`[aria-label="More actions for ${name}"]`)!.click(),
    );
    await settle();
    await act(async () => menuItem(label)!.click());
    await settle();
  };
  try {
    expect(decisionsOf("a.ts")).toEqual(["undecided", "undecided"]);
    await fromMenu("a.ts", "Reject file");
    expect(decisionsOf("a.ts")).toEqual(["Rejected", "Rejected"]);
    expect(decisionsOf("b.ts")).toEqual(["undecided"]);
    await fromMenu("b.ts", "Accept file");
    expect(decisionsOf("b.ts")).toEqual(["Accepted"]);
    expect(container.querySelector(".acpmux-revert-count")?.textContent).toBe("2 changes rejected");
    await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-revert-send")!.click());
    await settle();
    expect(sent.length).toBe(1);
    expect(sent[0]!.keys.length).toBe(2);
    expect(sent[0]!.prompt).toContain("+changed three");
    expect(sent[0]!.prompt).toContain("+changed thirty-five");
    expect(sent[0]!.prompt).not.toContain("changed two");
    expect(decisionsOf("a.ts")).toEqual(["Revert requested", "Revert requested"]);
    // A file whose changes already went back to the agent offers nothing more to decide.
    await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="More actions for a.ts"]')!.click());
    await settle();
    expect(menuItem("Reject file")).toBeUndefined();
    expect(menuItem("Accept file")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});
