// l10n-allow-file: test fixture commands and subagent names, not shipped UI.
// The one-line composer hat's background commands (cmux#65782). It read "2 background commands running"
// then two bare >_ marks, and the person asked "what is the purpose of this?". Each running command is
// now a chip after the sentence that names it (its description, else its short command: Claude's
// Bash calls carry a description, Codex's terminals do not), says how long it has run, opens its live
// output on a click, and stops only itself from its stop. With nothing running the hat is gone.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom, trackReactScheduler } from "./support/domTeardown";

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
  // The arm, as the gallery's stage frame pins it (experiments/experiment.ts, source 1); each test sets it.
  cmuxExperiments: {},
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

trackReactScheduler();
const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { trayItems } = await import("../src/agent-session/acpmux/subagents/runningTray");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;
type BackgroundCommand = import("../src/agent-session/acpmux/session-info/processes").BackgroundCommand;

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");

const now = Date.now();
// A Claude background Bash call: acpmux's registry lists it with the call's description.
const claudeServer: BackgroundCommand = {
  id: "s/1",
  command: "cd webviews && bun run dev --port 5173",
  description: "Start the webviews dev server",
  processId: "s/1",
  toolCallId: "call-claude",
  state: "running",
  startedAt: now - 75_000,
};
// A Codex background terminal: no description, named by what its command does (commandRules.ts).
const codexTests: BackgroundCommand = {
  id: "s/2",
  command: "cd /repo && cargo test -p acpmux --lib",
  processId: "s/2",
  toolCallId: "call-codex",
  state: "running",
  startedAt: now - 12_000,
};
// One only the transcript knows (no process id yet): it is named and opens, but has no stop.
const transcriptOnly: BackgroundCommand = {
  id: "call-tail",
  command: "tail -f /tmp/build.log",
  toolCallId: "call-tail",
  state: "running",
  startedAt: now - 5_000,
};
const reviewer: Subagent = {
  id: "agent-reviewer",
  parent: null,
  name: "Reviewer",
  task: "Review the fold motion",
  state: "running",
  background: true,
  startedAt: now - 60_000,
  harness: "codex",
};

async function mount(items: ReturnType<typeof trayItems>, props: Record<string, unknown> = {}) {
  scope.cmuxExperiments = { "composer-hat-line-deck": "trail", "subagent-tray-fold-head": "line" };
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const render = async (next: ReturnType<typeof trayItems>) =>
    act(async () =>
      root.render(
        createElement(SubagentTray, {
          items: next,
          working: true,
          waiting: new Set<string>(),
          onOpen: () => {},
          ...props,
        }),
      ),
    );
  await render(items);
  const chips = () => [...host.querySelectorAll<HTMLElement>("[data-command-chip]")];
  const head = () => host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head");
  const click = async (node: Element) =>
    act(async () => {
      node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    });
  return { host, chips, head, click, render, done: async () => act(async () => root.unmount()) };
}

describe("the one-line hat's background commands", () => {
  test("each running command is a chip with its name and time, after the sentence", async () => {
    const { host, chips, done } = await mount(trayItems([], [claudeServer, codexTests], [], true));
    try {
      expect(host.querySelector(".acpmux-running-tray__title")?.textContent).toBe("2 background commands running");
      const names = chips().map((chip) => chip.querySelector(".acpmux-hat-command__name")?.textContent);
      // Longest-running first, as the line orders its marks; Claude's by its description, Codex's by its work.
      expect(names).toEqual(["Start the webviews dev server", "Testing acpmux"]);
      const times = chips().map((chip) => chip.querySelector(".acpmux-hat-command__time")?.textContent ?? "");
      expect(times[0]).toMatch(/1m/);
      expect(times[1]).toMatch(/1\ds|\d+s/);
      // The whole command is the chip's tooltip; no bare terminal mark is left on the line.
      expect(chips()[0]!.getAttribute("title")).toBe(claudeServer.command);
      expect(host.querySelectorAll(".acpmux-hat-deck__mark:not([data-command-chip]):not([data-blank])").length).toBe(0);
    } finally {
      await done();
    }
  });

  test("a click opens the command's output and leaves the hat folded", async () => {
    const opened: BackgroundCommand[] = [];
    const { chips, head, click, done } = await mount(trayItems([], [claudeServer, codexTests], [], true), {
      onOpenCommand: (command: BackgroundCommand) => opened.push(command),
      canOpenTerminal: true,
    });
    try {
      await click(chips()[1]!.querySelector(".acpmux-hat-command__name")!);
      expect(opened.map((command) => command.id)).toEqual(["s/2"]);
      expect(head()?.getAttribute("aria-expanded")).toBe("false");
    } finally {
      await done();
    }
  });

  test("its stop stops only that command, by its process, and opens nothing", async () => {
    const stopped: string[] = [];
    const opened: BackgroundCommand[] = [];
    const { chips, head, click, done } = await mount(trayItems([], [claudeServer, transcriptOnly], [], true), {
      onOpenCommand: (command: BackgroundCommand) => opened.push(command),
      canOpenTerminal: true,
      stopProcess: async (id: string) => {
        stopped.push(id);
      },
    });
    try {
      const server = chips().find((chip) => chip.title === claudeServer.command)!;
      const tail = chips().find((chip) => chip.title === transcriptOnly.command)!;
      // A command only the transcript knows has no process to kill: no stop on its chip.
      expect(tail.querySelector("[data-command-stop]")).toBeNull();
      const stop = server.querySelector<HTMLElement>("[data-command-stop]")!;
      expect(stop.getAttribute("title")).toBe("Stop only this command");
      await click(stop);
      expect(stopped).toEqual(["s/1"]);
      expect(opened).toEqual([]);
      expect(head()?.getAttribute("aria-expanded")).toBe("false");
      expect(stop.getAttribute("data-state")).toBe("stopping");
    } finally {
      await done();
    }
  });

  test("subagents keep their marks; only commands become chips", async () => {
    const { host, chips, done } = await mount(trayItems([reviewer], [codexTests], [], true));
    try {
      expect(chips().length).toBe(1);
      expect(host.querySelectorAll(".acpmux-hat-deck__mark:not([data-command-chip]):not([data-blank])").length).toBe(1);
    } finally {
      await done();
    }
  });

  test("the hat goes once no command runs", async () => {
    const { host, chips, render, done } = await mount(trayItems([], [claudeServer], [], true));
    try {
      expect(chips().length).toBe(1);
      await render(trayItems([], [{ ...claudeServer, state: "completed", endedAt: now }], [], true));
      expect(host.querySelector(".acpmux-running-tray")).toBeNull();
    } finally {
      await done();
    }
  });
});
