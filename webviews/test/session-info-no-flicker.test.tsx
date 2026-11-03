// l10n-allow-file: test fixture chat text, not shipped UI.
// Session Info paints nothing for an update that changes nothing it shows (Leo, 2026-11-03: "i don't
// want to see flickers of the session info or anything when there's random re-renders EVER"). The
// pane mounts Session Info open, then streams a reply token by token, adds read-only tool calls that
// produce nothing, and ticks the chat's usage and session list with new objects holding the same
// values: the panel's DOM takes no mutation at all (a MutationObserver on its root), its frame keeps
// its box, and its sections do not render again.
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { useSessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import {
  resetSessionInfoState,
  setSessionInfoMore,
  setSessionInfoOpen,
  setSessionInfoSection,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import * as outputsSection from "../src/agent-session/acpmux/session-info/OutputsSection";
import * as environmentSection from "../src/agent-session/acpmux/session-info/EnvironmentSection";
import type { SessionInfoProcess } from "../src/agent-session/acpmux/session-info/processes";
import { activity, assistant, chat, tool, user } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  class FakeResizeObserver {
    observe() {}
    disconnect() {}
  }
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: FakeResizeObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetSessionInfoState();
  setSessionInfoMore(true);
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => setChatDisplay({}));

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetSessionInfoState();
  setHeaderState({ inspector: false });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const CWD = "/Users/you/src/atlas-web";
const PANE_WIDTH = 1200;
const UPDATES = 50;

const edited = (path: string, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path: `${CWD}/${path}`, oldText: "a\n", newText }] });

/// The chat as acpmux sends it on update `step`: every array and object new, as a snapshot is.
function streamed(base: AcpmuxSnapshot, step: number): AcpmuxSnapshot {
  const reads = Array.from({ length: Math.floor(step / 5) }, (_, index) =>
    tool(`Run git status ${index}`, "execute", "completed"),
  );
  const rows: AcpmuxRow[] = [
    ...base.rows.map((row) => ({ ...row })),
    activity(reads, 2),
    { ...assistant("token ".repeat(step), 1), streaming: true },
  ];
  return {
    ...base,
    rows,
    isWorking: true,
    // A usage tick: a new summary and session list with the same values.
    summary: { ...base.summary!, usage: { ...base.summary!.usage! } },
    sessions: base.sessions.map((entry) => ({ ...entry })),
  };
}

test(`${UPDATES} streamed tokens, tool calls and usage ticks paint nothing in Session Info`, async () => {
  const container = installDom();
  // The sections' own components, which an update that changes nothing they list must not draw again
  // (spied before the mount, so the tree is drawn with the spies from the start).
  const outputsRenders = spyOn(outputsSection, "OutputsSection");
  const environmentRenders = spyOn(environmentSection, "EnvironmentSection");
  const first = chat([user("Add retries", 4), activity([edited("src/fetch.ts", "a\nb\n")], 3)]);
  let push: (snapshot: AcpmuxSnapshot) => void = () => {};
  let panelRenders = 0;
  function Pane() {
    const [snapshot, setSnapshot] = useState(first);
    const [shell, setShell] = useState<HTMLElement | null>(null);
    push = setSnapshot;
    // As App.tsx passes them: callbacks made again on every render.
    const sessionInfo = useSessionInfo({
      snapshot,
      shell,
      machineName: "Studio",
      onOpenOutput: (path) => void path,
      onOpenUrl: (url) => void url,
      onOpenFolder: (path) => void path,
      processes: { processes: [], listed: true },
      onRender: () => panelRenders++,
    });
    return (
      <section
        className="acpmux-shell"
        ref={(element) => {
          if (element && element !== shell) {
            Object.defineProperty(element, "clientWidth", { configurable: true, get: () => PANE_WIDTH });
            Object.defineProperty(element, "clientHeight", { configurable: true, get: () => 900 });
            setShell(element);
          }
        }}
      >
        <div className="acpmux-main">
          {snapshot.rows.map((row) => (
            <p key={row.id}>{row.text}</p>
          ))}
        </div>
        {sessionInfo.panel}
      </section>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane />);
  });
  await act(async () => setSessionInfoOpen(true));
  // The first streamed update settles anything the panel draws once it first sees a running chat.
  await act(async () => push(streamed(first, 0)));
  // fixed-wait: timers and frames the updates scheduled run inside the observed window.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 50)));
  const panel = container.querySelector<HTMLElement>("aside.acpmux-session-info");
  expect(panel).not.toBeNull();
  expect(panel!.querySelector('[data-section="outputs"]')).not.toBeNull();
  // The spies count the sections' renders: they drew at the mount.
  expect(outputsRenders.mock.calls.length).toBeGreaterThan(0);
  expect(environmentRenders.mock.calls.length).toBeGreaterThan(0);

  const mutations: string[] = [];
  const record = (records: MutationRecord[]) => {
    for (const each of records) {
      const target = each.target as Element;
      const where =
        target.nodeType === 1 ? target.className || target.tagName : `#text in ${target.parentElement?.className}`;
      mutations.push(`${each.type}${each.attributeName ? `:${each.attributeName}` : ""} ${String(where)}`);
    }
  };
  const observer = new dom!.window.MutationObserver(record);
  observer.observe(panel!, { subtree: true, childList: true, attributes: true, characterData: true });
  const frame = () => `${panel!.getAttribute("style")}|${panel!.className}`;
  const before = frame();
  const rendersBefore = panelRenders;
  outputsRenders.mockClear();
  environmentRenders.mockClear();
  const sections = () => [...panel!.querySelectorAll("section")];
  const drawn = sections();

  for (let step = 1; step <= UPDATES; step++) {
    await act(async () => push(streamed(first, step)));
    expect(frame()).toBe(before);
  }
  // fixed-wait: timers and frames the updates scheduled run inside the observed window.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 50)));
  record(observer.takeRecords());
  observer.disconnect();

  expect(container.querySelector("aside.acpmux-session-info")).toBe(panel);
  // The same section elements, none mounted again.
  expect(sections().every((element, index) => element === drawn[index])).toBe(true);
  expect(sections()).toHaveLength(drawn.length);
  expect(mutations.slice(0, 20)).toEqual([]);
  // The transcript took every update; the panel drew for none of them.
  expect(container.querySelector(".acpmux-main")?.textContent).toContain("token ".repeat(UPDATES).trim());
  // The panel's frame follows the chat (it reads the rows' overflow); its sections do not draw again.
  expect(panelRenders - rendersBefore).toBeLessThanOrEqual(UPDATES);
  expect(outputsRenders).toHaveBeenCalledTimes(0);
  expect(environmentRenders).toHaveBeenCalledTimes(0);
  outputsRenders.mockRestore();
  environmentRenders.mockRestore();
});

// The sections keep the rows they were drawn with while no row is added, but not the tool calls those
// rows hold: in a chat on another machine a background task's row shows its call once the transcript
// holds it, and a call that lands in the turn's existing activity row adds no row.
test("a call added to an existing row lets a remote chat's background task show it", async () => {
  const container = installDom();
  const base = chat([user("Run the tests", 3)]);
  const remote: AcpmuxSnapshot = { ...base, summary: { ...base.summary!, peer: "mini" } };
  const server: SessionInfoProcess = {
    id: "s1/a",
    command: "pytest -x",
    startedAt: 1_000,
    state: "running",
    toolCallId: "call-test",
  };
  const withCalls = (ids: string[]): AcpmuxSnapshot => ({
    ...remote,
    rows: [
      ...remote.rows,
      {
        ...activity(
          ids.map((id) => ({
            ...tool(`Run ${id}`, "execute", "completed"),
            tool: { id, title: id, kind: "execute", status: "completed" },
          })),
          2,
        ),
        id: "turn-activity",
      },
    ],
  });
  let push: (snapshot: AcpmuxSnapshot) => void = () => {};
  function Pane() {
    const [snapshot, setSnapshot] = useState(withCalls(["call-ls"]));
    push = setSnapshot;
    const sessionInfo = useSessionInfo({
      snapshot,
      shell: null,
      processes: { processes: [server], listed: true },
      onShowCall: () => true,
    });
    return <section className="acpmux-shell">{sessionInfo.panel}</section>;
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane />);
  });
  await act(async () => {
    setSessionInfoSection("tasks", true);
    setSessionInfoOpen(true);
  });
  const open = () =>
    container.querySelector<HTMLButtonElement>(
      "li.acpmux-session-info-task--command button.acpmux-session-info-task__open",
    );
  expect(open()).not.toBeNull();
  expect(open()!.disabled).toBe(true);
  // The call lands in the same activity row: no row is added.
  await act(async () => push(withCalls(["call-ls", "call-test"])));
  expect(open()!.disabled).toBe(false);
});
