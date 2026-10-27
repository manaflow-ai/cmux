// l10n-allow-file: test fixtures.
// The sent-message row (SentMessageLine.tsx) a shell `acpmux send` draws: its sentence, the
// message's first line, and what opens under it.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { acpmuxSendCall } from "./acpmuxSends";
import { toolGroups } from "./toolGroups";
import { AcpmuxSendLine } from "./SentMessageLine";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";
import { SubsessionContext, SubsessionStore } from "../subagents/subsessions";
import type { AcpmuxSessionEntry } from "../sessionList";

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
    saved.set(key, scope[key]);
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
  root = undefined;
  resetTranscriptDisclosure();
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

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const bash = (command: string, fields: Partial<Tool> = {}): Tool => ({
  id: `toolu_${command.length}`,
  title: command.slice(0, 120),
  kind: "execute",
  status: "completed",
  command,
  description: "Report merge to coord-deputy",
  ...fields,
});

async function line(tool: Tool, store?: SubsessionStore, opened: string[] = []): Promise<HTMLElement> {
  const send = acpmuxSendCall(tool);
  if (!send) throw new Error(`not a send: ${tool.command}`);
  const row = <AcpmuxSendLine tool={tool} send={send} />;
  if (!store) return render(row);
  const chats = { store, open: (id: string) => void opened.push(id) };
  return render(<SubsessionContext.Provider value={chats}>{row}</SubsessionContext.Provider>);
}

const listed = (...entries: Partial<AcpmuxSessionEntry>[]) => {
  const store = new SubsessionStore();
  store.set(entries.map((entry, at) => ({ sessionId: `s${at}`, ...entry }) as AcpmuxSessionEntry));
  return store;
};

test("a sent message reads its target, how it was taken and its first line, and opens to all of it", async () => {
  const container = await line(
    bash("acpmux send --no-wait coord-deputy - <<'EOF'\n## Merged #4182\n\nThe review passed.\nEOF", {
      output: "queued",
    }),
  );
  const row = container.querySelector<HTMLButtonElement>(".cv-sent")!;
  expect(row.textContent).toBe("Sent message to coord-deputy · queuedMerged #4182");
  expect(row.dataset.sendState).toBe("sent");
  expect(row.classList.contains("is-live")).toBe(false);
  expect(row.getAttribute("aria-expanded")).toBe("false");
  await act(async () => row.click());
  expect(row.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(".cv-subsession__under h2")?.textContent).toBe("Merged #4182");
  // The command stays one more click away, behind Raw.
  expect(container.querySelector(".cv-shell")).toBeNull();
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-subsession__toggle")!.click());
  expect(container.querySelector(".cv-shell")?.textContent).toContain("acpmux send --no-wait coord-deputy");
});

test("in flight it is live, with the spinner", async () => {
  const running = await line(bash("acpmux send lane 'status?'", { status: "in_progress" }));
  const row = running.querySelector<HTMLButtonElement>(".cv-sent")!;
  expect(row.textContent).toBe("Sending message to lanestatus?");
  expect(row.classList.contains("is-live")).toBe(true);
  expect(row.querySelector(".cv-tool__icon svg")).not.toBeNull();
});

test("a send whose text comes from a file names only its target", async () => {
  const unknown = await line(bash(`acpmux send reports:leo "$(cat /tmp/summary.md)"`, { output: "" }));
  expect(unknown.querySelector(".cv-sent")!.textContent).toBe("Sent message to reports:leo");
});

test("a captured file body is rendered, while an unavailable file keeps Raw as the fallback", async () => {
  const captured = bash("acpmux send --no-wait reports:leo - < /tmp/summary.md", { output: "queued" });
  captured.inputPath = { path: "/tmp/summary.md", canonical: "/tmp/summary.md" };
  captured.diffs = [
    {
      path: "/tmp/summary.md",
      canonical: "/tmp/summary.md",
      newText: "## Captured summary\n\n- **Ready**",
      fragment: true,
      fromInput: true,
    },
  ];
  const rendered = await line(captured);
  await act(async () => rendered.querySelector<HTMLElement>(".cv-sent")!.click());
  expect(rendered.querySelector(".cv-subsession__under h2")?.textContent).toBe("Captured summary");
  expect(rendered.querySelector(".cv-subsession__under strong")?.textContent).toBe("Ready");
  // Without a captured event body, the parser still marks this as a file input and the row falls
  // back to Raw; it must never inspect `/tmp/summary.md` while rendering history.
  expect(acpmuxSendCall(bash("acpmux send --no-wait reports:leo - < /tmp/summary.md", { output: "queued" }))).toMatchObject({
    fileInput: true,
  });
});

test("a failed send says it could not send and opens to its output", async () => {
  const container = await line(
    bash("acpmux send perf-lane 'Profile it.'", {
      status: "failed",
      output: 'Exit code 4\nacpmux: no_session: no session matches "perf-lane"',
    }),
  );
  const row = container.querySelector<HTMLButtonElement>(".cv-sent")!;
  expect(row.textContent).toBe("Couldn't send to perf-lane");
  expect(row.dataset.sendState).toBe("failed");
  await act(async () => row.click());
  expect(container.querySelector(".cv-shell")?.textContent).toContain("no_session");
});

test("toolGroups draws a send as its own entry, between the commands around it", () => {
  const item = (tool: Tool): AcpmuxActivity => ({ kind: "tool", text: tool.title, tool });
  const groups = toolGroups([
    item(bash("git status", { id: "a" })),
    item(bash("acpmux send lane 'status?'", { id: "b" })),
    item(bash("git log -1", { id: "c" })),
  ]);
  expect(groups.map((group) => group.type)).toEqual(["item", "send", "item"]);
});

test("a compound command's send says the other work, which stays behind Raw", async () => {
  const container = await line(
    bash("cd ~/wt && git fetch -q && acpmux send --no-wait --from me coord-deputy 'Restore base.'; reach box 'df -h'", {
      output: "queued",
    }),
  );
  const row = container.querySelector<HTMLElement>(".cv-sent")!;
  expect(row.textContent).toBe("Sent message to coord-deputy · queued · and 2 more commandsRestore base.");
  await act(async () => row.click());
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-subsession__toggle")!.click());
  expect(container.querySelector(".cv-shell")?.textContent).toContain("git fetch -q");
});

const chats = () => listed({ name: "coord-deputy" }, { name: "studio-mac/scroll-jitter", peer: "studio-mac" });

test("the target opens its chat when the session list has it, without opening the row", async () => {
  const opened: string[] = [];
  const container = await line(bash("acpmux send coord-deputy 'hi'"), chats(), opened);
  const link = container.querySelector<HTMLButtonElement>(".cv-sent__target")!;
  expect(link.textContent).toBe("coord-deputy");
  await act(async () => link.click());
  expect(opened).toEqual(["s0"]);
  expect(container.querySelector(".cv-sent")!.getAttribute("aria-expanded")).toBe("false");
});

test("a host:name target finds the peer's chat listed as host/name", async () => {
  const opened: string[] = [];
  const container = await line(bash("acpmux send studio-mac:scroll-jitter 'hi'"), chats(), opened);
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-sent__target")!.click());
  expect(opened).toEqual(["s1"]);
});

test("a target the session list does not have is plain text", async () => {
  const container = await line(bash("acpmux send reports:leo 'hi'"), chats());
  expect(container.querySelector(".cv-sent__target")).toBeNull();
  expect(container.querySelector(".cv-sent")!.textContent).toContain("Sent message to reports:leo");
});

test("a target that is a listed chat's id opens that chat", async () => {
  const opened: string[] = [];
  const container = await line(bash("acpmux send s0 'hi'"), chats(), opened);
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-sent__target")!.click());
  expect(opened).toEqual(["s0"]);
});

test("a send that fails while open shows its Raw", async () => {
  const command = "acpmux send perf-lane 'Profile it.'";
  const container = await line(bash(command, { status: "in_progress" }));
  await act(async () => container.querySelector<HTMLElement>(".cv-sent")!.click());
  expect(container.querySelector(".cv-shell")).toBeNull();
  const failed = bash(command, { status: "failed", output: "Exit code 4\nacpmux: no_session" });
  await act(async () => root!.render(<AcpmuxSendLine tool={failed} send={acpmuxSendCall(failed)!} />));
  expect(container.querySelector(".cv-shell")?.textContent).toContain("no_session");
});

test("a send the call does not say went reads only who it was for", async () => {
  const container = await line(
    bash("git push -q && acpmux send --no-wait lane 'Pushed.'; git status --short", { exitCode: 0, output: "" }),
  );
  const row = container.querySelector<HTMLElement>(".cv-sent")!;
  expect(row.dataset.sendState).toBe("ended");
  expect(row.textContent).toBe("Message to lane · and 2 more commandsPushed.");
});
