// l10n-allow-file: synthetic subagent names for navigation regression tests.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { ReactNode } from "react";
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
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  innerWidth: 900,
  innerHeight: 800,
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|Event)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
const { SubagentsSection } = await import("../src/agent-session/acpmux/inspector/SubagentsSection");
const { SubagentListRow, SubagentPaneContext } = await import("../src/agent-session/acpmux/subagents/SubagentGroup");
const { ChildSessionRows } = await import("../src/agent-session/acpmux/inspector/ChildSessionRows");
const host = document.getElementById("root")!;
const root = createRoot(host);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
const agent = {
  id: "01a15779/toolu_01Oyc",
  name: "01a15779/toolu_01Oyc",
  task: "Review pane placement",
  parent: null,
  state: "running",
  startedAt: Date.now(),
};
const waiting = new Set<string>();
type Open = (id: string, event?: { metaKey: boolean }) => void;
const surfaces: [string, (open: Open) => ReactNode][] = [
  [
    "transcript group",
    (open) => (
      <SubagentPaneContext.Provider value={open}>
        <SubagentListRow row={{ id: "row", version: 1, kind: "subagent", at: 1, subagents: [agent] }} />
      </SubagentPaneContext.Provider>
    ),
  ],
  [
    "tray",
    (open) => (
      <SubagentTray
        items={[{ kind: "agent", id: agent.id, agent, depth: 0 }]}
        working
        waiting={waiting}
        onOpen={open}
      />
    ),
  ],
  ["summary", (open) => <SubagentStatusList agents={[agent]} waiting={waiting} onOpen={open} />],
  ["Session Info", (open) => <SubagentsSection agents={[agent]} waiting={waiting} onOpen={open} />],
];
for (const [name, surface] of surfaces) {
  test(`${name}: readable task name, raw identity available to hover and VoiceOver`, async () => {
    await act(async () => root.render(surface(() => {})));
    const button = host.querySelector<HTMLButtonElement>("button")!;
    expect(button.textContent).toContain(agent.task);
    expect(button.textContent).not.toContain(agent.id);
    expect(button.title || host.textContent).toContain(agent.id);
    expect(button.getAttribute("aria-label")).toContain(agent.id);
  });
  test(`${name}: ordinary and Cmd-click preserve destination intent`, async () => {
    const calls: [string, boolean][] = [];
    await act(async () => root.render(surface((id, event) => calls.push([id, event?.metaKey ?? false]))));
    const button = host.querySelector<HTMLButtonElement>("button")!;
    await act(async () => button.click());
    await act(async () => button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, metaKey: true })));
    expect(calls).toEqual([
      [agent.id, false],
      [agent.id, true],
    ]);
  });
}
test("child-session row preserves Cmd-click and exposes identity", async () => {
  const calls: boolean[] = [];
  await act(async () =>
    root.render(
      <ul>
        <ChildSessionRows
          sessions={[{ sessionId: "child-1", title: "Review tests", state: "idle" }]}
          onOpen={(_id, event?: { metaKey: boolean }) => calls.push(event?.metaKey ?? false)}
        />
      </ul>,
    ),
  );
  const button = host.querySelector<HTMLButtonElement>("button")!;
  await act(async () => button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, metaKey: true })));
  expect(calls).toEqual([true]);
  expect(button.title).toContain("child-1");
});
