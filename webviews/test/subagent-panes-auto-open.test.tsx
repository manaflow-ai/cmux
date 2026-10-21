// l10n-allow-file: test fixture subagent names, not shipped UI.
// A subagent the chat starts stays in the chat: no pane of its own opens unless the user turned
// that on (subagents/subagentPanes.ts `useOpenNewSubagents`). Leo 2026-10-20: a reviewer subagent
// opened a pane right of the chat by itself. The switch's stored value is
// subagent-panes-default-off.test.ts; this one runs the hook on a subagent that starts while the
// pane shows the chat.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useOpenNewSubagents } = await import("../src/agent-session/acpmux/subagents/subagentPanes");
const { SUBAGENTS } = await import("../src/agent-session/acpmux/subagents/subagentFold");

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const CHAT = "0190a000-0000-7000-8000-0000000000d1";
const group = (state: string) => [
  {
    id: "group-1",
    kind: SUBAGENTS,
    subagents: [{ id: "reviewer", parent: null, name: "Reviewer", state, startedAt: Date.now() }],
  },
];

/// Shows the chat with no subagent, then with one that just started; the panes it asked for.
async function opened(enabled: boolean) {
  const asked: string[] = [];
  const Probe = ({ rows }: { rows: unknown[] }) => {
    useOpenNewSubagents(CHAT, rows as never, undefined, enabled, (id) => asked.push(id));
    return null;
  };
  const root = createRoot(document.getElementById("root")!);
  await act(async () => root.render(createElement(Probe, { rows: [] })));
  await act(async () => root.render(createElement(Probe, { rows: group("running") })));
  await act(async () => root.render(createElement(Probe, { rows: group("running") })));
  await act(async () => root.unmount());
  return asked;
}

test("a subagent the chat starts opens no pane while the switch is off", async () => {
  expect(await opened(false)).toEqual([]);
});

test("with the switch on, a subagent the chat starts opens one pane, once", async () => {
  expect(await opened(true)).toEqual(["reviewer"]);
});
