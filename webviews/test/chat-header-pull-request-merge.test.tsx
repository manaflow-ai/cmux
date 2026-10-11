// Merge from the PR chip (cx-ncc.77.4, Codex desktop's): a green pull request's status popover
// offers Merge, which asks once more inline (no dialog) and then merges that pull request; the
// chip says it merged. One not ready to merge offers none, and a refusal says why inline.
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
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The popover places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));

const green = {
  url: "https://github.com/o/r/pull/7",
  number: 7,
  title: "Merge from the chip",
  state: "open",
  review: "approved",
  mergeable: "mergeable",
  checks: { state: "passing", passed: 2, total: 2 },
  checkList: [
    { name: "build", state: "passed" },
    { name: "test", state: "passed" },
  ],
};

async function render(merge: (number: number) => Promise<unknown>, pullRequest: object = green) {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onBrowser={() => {}}
        summary={null}
        menu={() => []}
        onMergePullRequest={merge}
      />,
    ),
  );
  await act(async () => applyHostEvent({ kind: "headerState", value: { version: 1, pullRequest } }));
  await act(async () => host.querySelector<HTMLButtonElement>("button.acpmux-header-pr")!.click());
  await settle();
  return root;
}

const button = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLButtonElement>(".acpmux-pr-status button")].find(
    (element) => element.textContent === name,
  );

test("Merge asks inline, then merges that pull request once and says so", async () => {
  const merged: number[] = [];
  const root = await render(async (number) => void merged.push(number));
  try {
    await act(async () => button("Merge")!.click());
    expect(merged).toEqual([]);
    expect(dom.window.document.querySelector(".acpmux-pr-merge")?.textContent).toContain(
      "Merge #7 into its base branch?",
    );
    await act(async () => button("Confirm merge")!.click());
    await settle();
    expect(merged).toEqual([7]);
    expect(dom.window.document.querySelector(".acpmux-pr-merge output")?.textContent).toBe("Merged");
    expect(button("Confirm merge")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a pull request that isn't ready offers no Merge, and a refusal says why", async () => {
  const blocked = await render(async () => undefined, {
    ...green,
    checks: { state: "failing", passed: 1, total: 2 },
    checkList: [
      { name: "build", state: "failed" },
      { name: "test", state: "passed" },
    ],
  });
  try {
    expect(button("Merge")).toBeUndefined();
  } finally {
    await act(async () => blocked.unmount());
  }
  const refused = await render(async () => {
    throw new Error("GitHub says this pull request isn't ready to merge.");
  });
  try {
    await act(async () => button("Merge")!.click());
    await act(async () => button("Confirm merge")!.click());
    await settle();
    expect(dom.window.document.querySelector(".acpmux-pr-merge [role=alert]")?.textContent).toBe(
      "GitHub says this pull request isn't ready to merge.",
    );
    expect(button("Merge")).toBeDefined();
  } finally {
    await act(async () => refused.unmount());
  }
});
