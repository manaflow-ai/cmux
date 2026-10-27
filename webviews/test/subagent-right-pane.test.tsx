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
const { SubagentListPanel, useSubagentList, SUBAGENT_LIST_REVEAL } =
  await import("../src/agent-session/acpmux/subagents/SubagentListPanel");
const { openSubagentPane } = await import("../src/agent-session/acpmux/subagents/subagentPanes");
const { openChildSession } = await import("../src/agent-session/acpmux/subagents/subagentNavigation");
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
  test(`${name}: readable task name without raw transport identity`, async () => {
    await act(async () => root.render(surface(() => {})));
    const button = host.querySelector<HTMLButtonElement>("button")!;
    expect(button.textContent).toContain(agent.task);
    expect(button.textContent).not.toContain(agent.id);
    expect(button.title ?? "").not.toContain(agent.id);
    expect(button.getAttribute("aria-label") ?? "").not.toContain(agent.id);
  });
  test(`${name}: ordinary clicks select and Cmd-clicks open background tabs`, async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const call = async (method: string, params: Record<string, unknown>) => {
      calls.push([method, params]);
      return { opened: true };
    };
    await act(async () =>
      root.render(
        surface((id, event) => {
          void openSubagentPane(call, id, !event?.metaKey);
        }),
      ),
    );
    const button = host.querySelector<HTMLButtonElement>("button")!;
    await act(async () => button.click());
    await act(async () => button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, metaKey: true })));
    expect(calls).toEqual([
      ["chat.subagentPane", { subagent: agent.id, focus: true }],
      ["chat.subagentPane", { subagent: agent.id, focus: false }],
    ]);
  });
}
test("child-session Cmd-click requests a background tab without exposing identity", async () => {
  const calls: Record<string, unknown>[] = [];
  const call = async (_method: string, params: Record<string, unknown>) => {
    calls.push(params);
  };
  await act(async () =>
    root.render(
      <ul>
        <ChildSessionRows
          sessions={[{ sessionId: "child-1", title: "Review tests", state: "idle" }]}
          onOpen={(_id, event?: { metaKey: boolean }) => void openChildSession(call, _id, event)}
        />
      </ul>,
    ),
  );
  const button = host.querySelector<HTMLButtonElement>("button")!;
  await act(async () => button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, metaKey: true })));
  await act(async () => button.click());
  expect(calls).toEqual([{ sessionId: "child-1", focus: false }, { sessionId: "child-1" }]);
  expect(button.title ?? "").not.toContain("child-1");
  expect(button.getAttribute("aria-label") ?? "").not.toContain("child-1");
});

test("View all requests the full list in the companion pane", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  let reveal: (value: string) => boolean;
  const finished = Array.from({ length: 7 }, (_, i) => ({
    kind: "agent" as const,
    id: String(i),
    depth: 0,
    agent: { ...agent, id: String(i), state: "completed", endedAt: Date.now() },
  }));
  function ViewAll() {
    const list = useSubagentList(async (method, params) => {
      calls.push([method, params]);
      return { opened: true };
    });
    reveal = list.reveal;
    if (list.shown)
      return (
        <SubagentListPanel
          agents={finished.map((row) => row.agent)}
          waiting={waiting}
          onOpen={(id, event) => {
            void openSubagentPane(async (method, params) => calls.push([method, params]), id, !event?.metaKey);
          }}
        />
      );
    return (
      <>
        <SubagentTray
          items={[]}
          finished={finished}
          working={false}
          waiting={waiting}
          onOpen={() => {}}
          onShowAll={list.show}
        />
      </>
    );
  }
  await act(async () => root.render(<ViewAll />));
  const more = host.querySelector<HTMLButtonElement>(".acpmux-running-tray__finished")!;
  await act(async () => more.click());
  expect(calls).toEqual([["chat.subagentList", {}]]);
  expect(host.querySelector("aside")).toBeNull();
  expect(host.querySelectorAll("li[data-finished]").length).toBe(3);
  await act(async () => {
    reveal(SUBAGENT_LIST_REVEAL);
  });
  const pane = host.querySelector("section.acpmux-main")!;
  expect(pane.querySelectorAll("li").length).toBe(7);
  await act(async () => pane.querySelector<HTMLButtonElement>("li button")!.click());
  expect(calls.at(-1)).toEqual(["chat.subagentPane", { subagent: "0", focus: true }]);
  await act(async () =>
    pane
      .querySelector<HTMLButtonElement>("li button")!
      .dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, metaKey: true })),
  );
  expect(calls.at(-1)).toEqual(["chat.subagentPane", { subagent: "0", focus: false }]);
});

test("native subagent placement distinguishes refusal from transport failure", async () => {
  await expect(openSubagentPane(async () => ({ opened: false }), "child-1", true)).resolves.toBe("refused");
  await expect(openSubagentPane(async () => ({ opened: true }), "child-1", true)).resolves.toBe("opened");
  await expect(openSubagentPane(async () => {
    throw new Error("disconnected");
  }, "child-1", true)).resolves.toBe("error");
});

test("subagent list hide callback stays stable across renders", async () => {
  const hides: unknown[] = [];
  const call = async () => ({ opened: true });
  function Probe() {
    hides.push(useSubagentList(call).hide);
    return null;
  }
  await act(async () => root.render(<Probe />));
  await act(async () => root.render(<Probe />));
  expect(hides[1]).toBe(hides[0]);
});
