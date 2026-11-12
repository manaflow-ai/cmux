// l10n-allow-file: test fixture commands, not shipped UI.
// A shell call that went on in the background shows how it stands on its own "Ran" row, in a "Ran
// N commands" group (CommandRow) or alone (ToolRow): the running mark while it runs there, then a
// check with its time, "Failed" or "Stopped". A background task's end whose call is not in the
// transcript is one line naming the command in a few words, never the raw `export PATH=…` text
// (Leo 2026-10-20). A click opens that line in place, never a terminal (Leo 2026-10-21: it
// replaced the whole window with an empty terminal); only its Open in terminal opens one.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxActivity, AcpmuxBackgroundState, AcpmuxBackgroundTask } from "../model";
import { BackgroundTaskNote } from "./BackgroundTaskNote";
import { SubagentNavContext } from "../subagents/subagentGroupModel";
import {
  BACKGROUND_TAIL_BYTES,
  BackgroundTaskOutputContext,
  prefetchBackgroundTaskOutput,
  readBackgroundTaskOutput,
  tailLines,
  type BackgroundTaskOutputReader,
} from "./backgroundTaskOutput";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { CommandRow } from "./CommandRow";
import { ToolRow } from "./ToolRow";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const STARTED = Date.UTC(2026, 9, 20, 9, 0, 0);
const call = (background?: AcpmuxBackgroundState): AcpmuxActivity => ({
  kind: "tool",
  text: "npm run dev",
  tool: {
    id: "bg1",
    title: "npm run dev",
    kind: "execute",
    status: "completed",
    command: "npm run dev",
    startedAt: STARTED,
    // The launch returned at once; the shell ran on.
    endedAt: STARTED + 200,
    ...(background ? { background } : {}),
  },
});

for (const [name, Row] of [
  ["CommandRow", CommandRow],
  ["ToolRow", ToolRow],
] as const) {
  test(`${name}: running in the background shimmers its words, with no mark at the edge and no time`, async () => {
    const container = await render(<Row item={call({ state: "running" })} />);
    const mark = container.querySelector(".cv-command__bg-state")!;
    expect(mark.getAttribute("title")).toBe(translate("tools.background.running"));
    expect(mark.textContent).toBe(translate("tools.background.running"));
    // Leo, 2026-11-03, on its spinner a whole column away from the words: "this is kinda weird looking".
    expect(container.querySelector(".cv-spinner")).toBeNull();
    const shimmer = container.querySelector(".cv-row-shimmer")!;
    expect(shimmer.getAttribute("aria-hidden")).toBe("true");
    expect(shimmer.hasAttribute("inert")).toBe(true);
    expect(container.querySelector(".cv-command__ok")).toBeNull();
    expect(container.querySelector(".cv-command__time")).toBeNull();
  });

  test(`${name}: finished in the background is a check with the shell's whole run time`, async () => {
    const container = await render(<Row item={call({ state: "completed", endedAt: STARTED + 6_100 })} />);
    expect(container.querySelector(".cv-command__bg-state")).toBeNull();
    expect(container.querySelector(".cv-row-shimmer")).toBeNull();
    expect(container.querySelector(".cv-command__ok")).not.toBeNull();
    // Its time runs to the shell's end, not the launch's 200ms.
    expect(container.querySelector(".cv-command__time")!.textContent).toBe(translate("duration.s", { n: "6.1" }));
  });

  test(`${name}: failed and stopped say so, a stop with the agent's reason on hover`, async () => {
    const failed = await render(<Row item={call({ state: "failed", endedAt: STARTED + 1_000 })} />);
    expect(failed.querySelector(".cv-command__failed")!.textContent).toBe(translate("tools.failed"));
    await act(async () => root!.unmount());
    root = undefined;
    const stopped = await render(
      <Row item={call({ state: "stopped", reason: "Stopped by the agent", endedAt: STARTED + 1_000 })} />,
    );
    const label = stopped.querySelector(".cv-command__stopped")!;
    expect(label.textContent).toBe(translate("bgTask.state.stopped"));
    expect(label.getAttribute("title")).toBe("Stopped by the agent");
  });
}

test("a command that never went to the background draws as before", async () => {
  const container = await render(<ToolRow item={call()} />);
  expect(container.querySelector(".cv-tool__meta")).toBeNull();
});

test("a background task's end without its call keeps the raw command visible", async () => {
  const command =
    'export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"; B=~/Projects/leo-workspace; cmux browser open https://example.com';
  const container = await render(<BackgroundTaskNote task={{ toolCallId: "bg9", command, state: "completed" }} />);
  const note = container.querySelector(".cv-bgtask")!;
  expect(note.textContent).toContain(command);
  expect(note.textContent).toContain(translate("bgTask.completedLead"));
  // No tooltip: the whole command is one click away, in the opened note.
  expect(note.getAttribute("title")).toBeNull();
});

// Leo, 2026-11-05, on a note reading "Background command completed hold": "what are you even holding
// for?". An agent's Monitor named "hold" reads as the tray reads it, what it does, then its name.
test("a background task an agent named reads as what it does, then its name", async () => {
  const container = await render(
    <BackgroundTaskNote
      task={{ toolCallId: "bg-hold", command: "sleep 840; echo t", description: "hold", state: "completed" }}
    />,
  );
  const named = container.querySelector<HTMLElement>(".cv-bgtask__title")!;
  expect(named.textContent).toBe("Waiting 14m · hold");
  expect(named.title).toBe("sleep 840; echo t");
  expect(container.querySelector(".cv-bgtask__command")).toBeNull();
});

test("a background task names and links its owner, and keeps its duration in the details", async () => {
  const opened: string[] = [];
  const task: AcpmuxBackgroundTask = {
    toolCallId: "bg-owner",
    command: "sleep 299; echo t",
    ownerId: "chat/helper-1",
    ownerTitle: "Cut create overhead",
    startedAt: STARTED,
    endedAt: STARTED + 6_100,
    state: "completed",
  };
  const container = await render(
    <SubagentNavContext.Provider value={(id) => opened.push(id ?? "")}>
      <BackgroundTaskNote task={task} />
    </SubagentNavContext.Provider>,
  );
  const owner = container.querySelector<HTMLElement>('.cv-bgtask__owner[role="link"]')!;
  expect(owner.textContent).toBe("Cut create overhead");
  expect(owner.dataset.deeplink).toBe("#subagent:chat/helper-1");
  expect(container.textContent).toContain("sleep 299; echo t");
  await click(owner);
  expect(opened).toEqual(["chat/helper-1"]);
  expect(container.querySelector("button.cv-bgtask")?.getAttribute("aria-expanded")).toBe("false");
  await click(container.querySelector("button.cv-bgtask")!);
  expect(container.textContent).toContain("6s");
});

test("a background task without an owner title does not show the owner id", async () => {
  const container = await render(
    <BackgroundTaskNote
      task={{ toolCallId: "bg-owner-id", ownerId: "chat/helper-2", command: "sleep 1", state: "completed" }}
    />,
  );
  expect(container.textContent).not.toContain("chat/helper-2");
  await click(container.querySelector("button.cv-bgtask")!);
  expect(container.textContent).not.toContain("chat/helper-2");
});

test("a stopped background task keeps its status and reason", async () => {
  const container = await render(
    <BackgroundTaskNote
      task={{
        toolCallId: "bg-stopped",
        command: "sleep 299; echo t",
        state: "stopped",
        reason: "Stopped by the agent",
      }}
    />,
  );
  const note = container.querySelector("button.cv-bgtask")!;
  expect(note.textContent).toContain(translate("bgTask.state.stopped"));
  await click(note);
  expect(container.textContent).toContain("Stopped by the agent");
});

/// What the page posts to the native host (CmuxNextAgentPane's `agentSession` handler).
function recordNative(): { method: string; params: Record<string, unknown> }[] {
  const posted: { method: string; params: Record<string, unknown> }[] = [];
  Object.assign(dom!.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params: Record<string, unknown> }) => {
            posted.push({ method: message.method, params: message.params });
            return { ok: true, value: { opened: true } };
          },
        },
      },
    },
  });
  return posted;
}
const terminals = (posted: { method: string; params: Record<string, unknown> }[]) =>
  posted.filter((post) => post.method === "chat.processTerminal").map((post) => post.params);
const click = (element: Element) => act(async () => (element as HTMLElement).click());
/// Lets the registry's answers land.
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

const LONG =
  'export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"; cd ~/src/app && cargo watch -x test';

test("a task with no output opens its command details and terminal action without a card", async () => {
  const container = await render(<BackgroundTaskNote task={{ toolCallId: "bg1", command: LONG, state: "failed" }} />);
  const posted = recordNative();
  const note = container.querySelector<HTMLButtonElement>("button.cv-bgtask")!;
  expect(note.getAttribute("aria-expanded")).toBe("false");
  // Collapsed: the one line and its chevron, no card.
  expect(container.querySelector(".cv-shell")).toBeNull();
  expect(note.querySelector(".cv-tool__chevron.cv-rotor")).not.toBeNull();
  await click(note);
  expect(note.getAttribute("aria-expanded")).toBe("true");
  expect(note.querySelector(".cv-rotor.is-open")).not.toBeNull();
  // A disclosure the transcript holds in place while it opens (foldAnchor.ts FOLD_TOGGLE).
  expect(note.matches("button.is-toggle[aria-expanded]")).toBe(true);
  const details = container.querySelector(".cv-bgtask__details")!;
  expect(details.id).toBe(note.getAttribute("aria-controls")!);
  expect(details.querySelector(".cv-bgtask__raw-command")!.textContent).toBe(LONG);
  expect(container.querySelector(".cv-shell")).toBeNull();
  // A failure keeps its red mark open.
  expect(note.dataset.state).toBe("failed");
  const open = container.querySelector<HTMLButtonElement>(".cv-bgtask__details button.cv-bgtask__open")!;
  expect(open.textContent).toBe(translate("shell.openInTerminal"));
  await click(open);
  expect(terminals(posted)).toEqual([{ toolCallId: "bg1" }]);
  // A second click closes it, still with no terminal.
  await click(note);
  expect(note.getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelector(".cv-shell")).toBeNull();
  expect(terminals(posted)).toEqual([{ toolCallId: "bg1" }]);
});

test("a task with output offers Open in terminal inside its opened card", async () => {
  const { reader } = registry(
    [
      {
        id: "s1/bg2",
        sessionId: "s1",
        toolCallId: "bg2",
        harness: "claude",
        command: "cargo watch -x test",
        state: "failed",
      },
    ],
    "output\n",
  );
  const container = await render(
    <BackgroundTaskOutputContext.Provider value={reader}>
      <BackgroundTaskNote task={{ toolCallId: "bg2", command: "cargo watch -x test", state: "failed" }} />
    </BackgroundTaskOutputContext.Provider>,
  );
  const posted = recordNative();
  expect(container.querySelector(".cv-bgtask__open")).toBeNull();
  await click(container.querySelector("button.cv-bgtask")!);
  await settle();
  const open = container.querySelector<HTMLButtonElement>(".cv-shell button.cv-bgtask__open")!;
  expect(open.textContent).toBe(translate("shell.openInTerminal"));
  await click(open);
  expect(terminals(posted)).toEqual([{ toolCallId: "bg2" }]);
  // The note stays open where it is.
  expect(container.querySelector("button.cv-bgtask")!.getAttribute("aria-expanded")).toBe("true");
});

test("the opened note shows the exit code and the harness's words on the end", async () => {
  const task: AcpmuxBackgroundTask = {
    toolCallId: "bg3",
    command: "pytest -x",
    state: "failed",
    exitCode: 2,
    summary: "2 tests failed",
  };
  const container = await render(<BackgroundTaskNote task={task} />);
  await click(container.querySelector("button.cv-bgtask")!);
  expect(container.querySelector(".cv-shell__exit")).toBeNull();
  expect(container.textContent).toContain("2 tests failed");
  expect(container.textContent).toContain("Exit code 2");
});

/// A process registry that lists `records` for chat `s1` and answers every tail with `text`.
function registry(records: Record<string, unknown>[], text?: string) {
  const asked: { method: string; params: unknown }[] = [];
  const reader: BackgroundTaskOutputReader = {
    sessionId: "s1",
    source: {
      listProcesses: async (sessionId) => {
        asked.push({ method: "list", params: sessionId });
        return { processes: records };
      },
      tailProcess: async (processId, maxBytes) => {
        asked.push({ method: "tail", params: { processId, maxBytes } });
        if (text === undefined) throw new Error("tail is Claude Code only for now");
        const bytes = new TextEncoder().encode(text);
        return { data: btoa(String.fromCharCode(...bytes)), fromByte: 0, nextByte: bytes.length, eof: true };
      },
    },
  };
  return { reader, asked };
}

test("opened, the note reads the end of the task's output from acpmux, once", async () => {
  const { reader, asked } = registry(
    [{ id: "s1/b7x", sessionId: "s1", toolCallId: "bg4", harness: "claude", command: "npm test", state: "failed" }],
    "\u001b[31mFAIL\u001b[0m src/upload.test.ts\n  expected 200, got 500\n",
  );
  const container = await render(
    <BackgroundTaskOutputContext.Provider value={reader}>
      <BackgroundTaskNote task={{ toolCallId: "bg4", command: "npm test", state: "failed" }} />
    </BackgroundTaskOutputContext.Provider>,
  );
  // Closed, nothing is read.
  await settle();
  expect(asked).toEqual([]);
  const note = container.querySelector("button.cv-bgtask")!;
  await click(note);
  await settle();
  expect(asked).toEqual([
    { method: "list", params: "s1" },
    { method: "tail", params: { processId: "s1/b7x", maxBytes: BACKGROUND_TAIL_BYTES } },
  ]);
  // Its colour codes stripped, as every shell card's output.
  expect(container.querySelector(".cv-shell__output")!.textContent).toBe(
    "FAIL src/upload.test.ts\n  expected 200, got 500",
  );
  // Closing and opening again reads nothing more.
  await click(note);
  await click(note);
  await settle();
  expect(asked.length).toBe(2);
});

test("a Codex task shows the registry's exit code and stays a quiet details row", async () => {
  const { reader, asked } = registry([
    { id: "s1/p9", sessionId: "s1", toolCallId: "bg5", harness: "codex", command: "make", exitCode: 101 },
  ]);
  const container = await render(
    <BackgroundTaskOutputContext.Provider value={reader}>
      <BackgroundTaskNote task={{ toolCallId: "bg5", command: "make", state: "failed" }} />
    </BackgroundTaskOutputContext.Provider>,
  );
  await click(container.querySelector("button.cv-bgtask")!);
  await settle();
  expect(asked.map((ask) => ask.method)).toEqual(["list"]);
  expect(container.textContent).toContain("Exit code 101");
  expect(container.querySelector(".cv-bgtask__details")).not.toBeNull();
  expect(container.querySelector(".cv-shell__output")).toBeNull();
});

test("a successful task does not show an exit code", async () => {
  const { reader } = registry([
    { id: "s1/p10", sessionId: "s1", toolCallId: "bg-ok", harness: "codex", command: "make" },
  ]);
  const container = await render(
    <BackgroundTaskOutputContext.Provider value={reader}>
      <BackgroundTaskNote task={{ toolCallId: "bg-ok", command: "make", state: "completed", exitCode: 0 }} />
    </BackgroundTaskOutputContext.Provider>,
  );
  await click(container.querySelector("button.cv-bgtask")!);
  await settle();
  expect(container.textContent).not.toContain("Exit code");
});

test("a task the registry does not list still opens with its command and nothing more", async () => {
  const { reader } = registry([]);
  const container = await render(
    <BackgroundTaskOutputContext.Provider value={reader}>
      <BackgroundTaskNote task={{ toolCallId: "bg6", command: "pytest -x", state: "completed" }} />
    </BackgroundTaskOutputContext.Provider>,
  );
  await click(container.querySelector("button.cv-bgtask")!);
  await settle();
  expect(container.querySelector(".cv-bgtask__raw-command")!.textContent).toBe("pytest -x");
  expect(container.querySelector(".cv-shell__output")).toBeNull();
  expect(container.querySelector(".cv-shell__exit")).toBeNull();
});

test("a known process id wins over a reused tool call id", async () => {
  const bytes = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
  const reader: BackgroundTaskOutputReader = {
    sessionId: "s1",
    source: {
      listProcesses: async () => ({
        processes: [
          { id: "s1/old", toolCallId: "bg", harness: "claude", state: "running" },
          { id: "s1/new", toolCallId: "bg", harness: "claude", state: "running" },
        ],
      }),
      tailProcess: async (processId) => ({ data: bytes(processId), fromByte: 0 }),
    },
  };
  const output = await readBackgroundTaskOutput(reader, "bg", "s1/old");
  expect(output.output).toBe("s1/old");
});

test("a finished task is read once; a read that failed or found it running is read again", async () => {
  const bytes = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
  const lists: string[] = [];
  let state = "running";
  let fail = false;
  const reader: BackgroundTaskOutputReader = {
    sessionId: "s1",
    source: {
      listProcesses: async () => {
        lists.push(state);
        if (fail) throw new Error("daemon away");
        return { processes: [{ id: "s1/p", toolCallId: "bg", harness: "claude", state, exitCode: 0 }] };
      },
      tailProcess: async () => ({ data: bytes(`done\n`), fromByte: 0 }),
    },
  };
  // Asked twice at once: one read.
  const [first, again] = await Promise.all([
    prefetchBackgroundTaskOutput(reader, "bg"),
    prefetchBackgroundTaskOutput(reader, "bg"),
  ]);
  expect(first).toBe(again);
  expect(first.running).toBe(true);
  // Running when read: its end may not be written yet, so the next ask reads again.
  state = "exited";
  expect((await prefetchBackgroundTaskOutput(reader, "bg")).running).toBeUndefined();
  // Ended: kept.
  await prefetchBackgroundTaskOutput(reader, "bg");
  expect(lists).toEqual(["running", "exited"]);
  // A failed read answers empty and is not kept.
  fail = true;
  expect(await prefetchBackgroundTaskOutput(reader, "other")).toEqual({ unread: true });
  fail = false;
  await prefetchBackgroundTaskOutput(reader, "other");
  expect(lists).toEqual(["running", "exited", "exited", "exited"]);
});

test("a click after a read-ahead that found the task still running reads again and opens the final output", async () => {
  const bytes = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
  let state = "running";
  const reader: BackgroundTaskOutputReader = {
    sessionId: "s-race",
    source: {
      listProcesses: async () => ({
        processes: [{ id: "s-race/p", toolCallId: "bg-race", harness: "claude", state, exitCode: 0 }],
      }),
      tailProcess: async () => ({
        data: bytes(state === "running" ? "partial\n" : "partial\nall done\n"),
        fromByte: 0,
      }),
    },
  };
  const container = await render(
    <BackgroundTaskOutputContext.Provider value={reader}>
      <BackgroundTaskNote task={{ toolCallId: "bg-race", command: "cargo test", state: "completed" }} />
    </BackgroundTaskOutputContext.Provider>,
  );
  // Focus reads ahead (as a hover does), and that read finds the task still running.
  await act(async () => (container.querySelector("button.cv-bgtask") as HTMLElement).focus());
  await settle();
  state = "exited";
  await click(container.querySelector("button.cv-bgtask")!);
  await settle();
  expect(container.querySelector(".cv-shell__output")!.textContent).toContain("all done");
});

test("a click after a read-ahead that failed reads again and opens the output", async () => {
  const bytes = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
  let away = true;
  const reader: BackgroundTaskOutputReader = {
    sessionId: "s-away",
    source: {
      listProcesses: async () => {
        if (away) throw new Error("daemon away");
        return {
          processes: [{ id: "s-away/p", toolCallId: "bg-away", harness: "claude", state: "exited", exitCode: 0 }],
        };
      },
      tailProcess: async () => ({ data: bytes("back again\n"), fromByte: 0 }),
    },
  };
  const container = await render(
    <BackgroundTaskOutputContext.Provider value={reader}>
      <BackgroundTaskNote task={{ toolCallId: "bg-away", command: "make", state: "completed" }} />
    </BackgroundTaskOutputContext.Provider>,
  );
  await act(async () => (container.querySelector("button.cv-bgtask") as HTMLElement).focus());
  await settle();
  away = false;
  await click(container.querySelector("button.cv-bgtask")!);
  await settle();
  expect(container.querySelector(".cv-shell__output")!.textContent).toContain("back again");
});

test("a drag across the note's line does not open it", async () => {
  const { reader } = registry([]);
  const container = await render(
    <BackgroundTaskOutputContext.Provider value={reader}>
      <BackgroundTaskNote task={{ toolCallId: "bg-drag", command: "make", state: "completed" }} />
    </BackgroundTaskOutputContext.Provider>,
  );
  const line = container.querySelector("button.cv-bgtask")!;
  await settle();
  await act(async () => {
    line.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 10, clientY: 10 }));
    line.dispatchEvent(
      new window.MouseEvent("click", { bubbles: true, button: 0, detail: 1, clientX: 30, clientY: 10 }),
    );
  });
  // Let the read the press asked for answer (an unguarded click would open the note then).
  await settle();
  await settle();
  expect(line.getAttribute("aria-expanded")).toBe("false");
});

test("a live tail keeps the last lines and removes terminal control escapes", () => {
  expect(
    tailLines("first\n\u001b]8;;https://example.test\u0007\u001b[31msecond\u001b[0m\u001b]8;;\u0007\nthird\n", 2),
  ).toBe("second\nthird");
});
