// l10n-allow-file: test fixtures, not shipped UI.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ProcessRegistry, ProcessSource } from "../src/agent-session/acpmux/session-info/processes";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useProcessRegistry, PROCESS_LIST_RECENT } = await import("../src/agent-session/acpmux/session-info/processes");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const SESSION = "history-close";
const rows = (running = false) =>
  Array.from({ length: 700 }, (_, n) => ({
    id: `${SESSION}/${n}`,
    sessionId: SESSION,
    command: `task ${n}`,
    state: running && n === 0 ? "running" : "exited",
    startedAt: n,
  }));

function harness() {
  const pending: ((reply: unknown) => void)[] = [];
  const calls: (number | undefined)[] = [];
  const source: ProcessSource = {
    listProcesses: (_session, recent) => {
      calls.push(recent);
      return new Promise((resolve) => pending.push(resolve));
    },
    watchProcesses: () => () => {},
  };
  let state: ProcessRegistry = { processes: [], listed: false };
  function View({ live, all }: { live: boolean; all: boolean }) {
    state = useProcessRegistry(source, SESSION, live, all);
    return null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  return {
    calls,
    state: () => state,
    render: async (live: boolean, all: boolean) => {
      await act(async () => root.render(<View live={live} all={all} />));
    },
    reply: async (processes: ReturnType<typeof rows>) => {
      await act(async () => pending.shift()!({ processes }));
    },
    close: async () => {
      await act(async () => root.unmount());
    },
  };
}

test("closing idle history releases old rows without listing again", async () => {
  const view = harness();
  try {
    await view.render(true, true);
    await view.reply(rows());
    expect(view.state().processes).toHaveLength(700);
    await view.render(false, false);
    expect(view.state().processes).toHaveLength(PROCESS_LIST_RECENT);
    expect(view.state().processes[0]?.id).toBe(`${SESSION}/200`);
    expect(view.state().listed).toBe(true);
    expect(view.calls).toEqual([undefined]);
  } finally {
    await view.close();
  }
});

test("closing history keeps old running processes while the recent list is pending", async () => {
  const view = harness();
  try {
    await view.render(true, true);
    await view.reply(rows(true));
    await view.render(false, false);
    expect(view.state().processes).toHaveLength(PROCESS_LIST_RECENT + 1);
    expect(view.state().processes[0]?.id).toBe(`${SESSION}/0`);
    expect(view.state().listed).toBe(true);
    expect(view.calls).toEqual([undefined, PROCESS_LIST_RECENT]);
  } finally {
    await view.close();
  }
});

test("a full-history reply arriving after the idle panel closes is ignored", async () => {
  const view = harness();
  try {
    await view.render(true, true);
    await view.reply(rows());
    await view.render(false, false);
    await view.render(true, true);
    await view.render(false, false);
    await view.reply(rows());
    expect(view.state().processes).toHaveLength(PROCESS_LIST_RECENT);
    expect(view.state().listed).toBe(true);
    expect(view.calls).toEqual([undefined, undefined]);
  } finally {
    await view.close();
  }
});
