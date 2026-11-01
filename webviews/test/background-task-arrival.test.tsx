// l10n-allow-file: test fixture commands, not shipped UI.
// A background task that starts while its list is drawn enters it (Leo 2026-10-20, directional
// motion): its row carries `data-enter="top"` (the lists are newest first), which ui/popupSurface.css
// plays once on mount, on the host's motion tokens. The rows a list is drawn with are simply there,
// so opening Session Info, the Summary or the finished fold never replays every row.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { useSessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import {
  resetSessionInfoState,
  setSessionInfoOpen,
  setSessionInfoSection,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import type { BackgroundCommand, SessionInfoProcess } from "../src/agent-session/acpmux/session-info/processes";
import { TasksSection } from "../src/agent-session/acpmux/session-info/TasksSection";
import { SummaryTasks } from "../src/agent-session/acpmux/summary/SummaryTasks";
import { assistant, chat, user } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
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
  return dom.window.document.getElementById("root")!;
}

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

const command = (id: string, text: string, state: BackgroundCommand["state"] = "running"): BackgroundCommand => ({
  id,
  command: text,
  state,
  startedAt: 1_000,
  ...(state === "running" ? {} : { endedAt: 2_000 }),
});

const entering = (container: HTMLElement, selector: string) =>
  [...container.querySelectorAll<HTMLElement>(selector)].map(
    (row) => `${row.textContent?.match(/pytest|tsc|cargo|vite|bun/)?.[0] ?? "?"}:${row.dataset.enter ?? "-"}`,
  );

/// The row's entrance finished playing (the stylesheet's `ui-enter` keyframe).
const played = (row: Element) =>
  act(async () => {
    row.dispatchEvent(new dom!.window.Event("animationend", { bubbles: true }));
  });

test("Session Info's new running task enters from the top; the ones it was drawn with do not", async () => {
  const container = installDom();
  const first = [command("a", "tsc --watch")];
  await act(async () => {
    root = createRoot(container);
    root.render(<TasksSection commands={first} />);
  });
  expect(entering(container, "li.acpmux-session-info-task--command")).toEqual(["tsc:-"]);
  await act(async () => root!.render(<TasksSection commands={[command("b", "pytest -x"), ...first]} />));
  expect(entering(container, "li.acpmux-session-info-task--command")).toEqual(["pytest:top", "tsc:-"]);
});

test("the Summary's new running task enters from the top; the ones it was drawn with do not", async () => {
  const container = installDom();
  const first = [command("a", "tsc --watch")];
  await act(async () => {
    root = createRoot(container);
    root.render(<SummaryTasks commands={first} />);
  });
  expect(entering(container, "li.acpmux-summary-task")).toEqual(["tsc:-"]);
  await act(async () => root!.render(<SummaryTasks commands={[command("b", "pytest -x"), ...first]} />));
  expect(entering(container, "li.acpmux-summary-task")).toEqual(["pytest:top", "tsc:-"]);
});

test("opening the finished fold does not replay its rows", async () => {
  const container = installDom();
  const commands = [command("a", "tsc --watch", "completed")];
  await act(async () => {
    root = createRoot(container);
    root.render(<TasksSection commands={commands} />);
  });
  const fold = container.querySelector<HTMLButtonElement>("button.acpmux-session-info-fold")!;
  await act(async () => fold.click());
  expect(entering(container, "li.acpmux-session-info-task--command")).toEqual(["tsc:-"]);
});

// Custom properties inherit, so a row's entrance must not pick up the axis or the travel of the
// surface it sits in (the Summary card enters from the right, and travels 100% inline): each edge
// sets both axes, and a surface inside another entering surface starts from the default distance.
test("an entering row inside an entering card keeps its own edge and distance", async () => {
  const css = await Bun.file(new URL("../src/ui/popupSurface.css", import.meta.url)).text();
  const rule = (selector: string) =>
    css.match(new RegExp(`${selector.replace(/[[\]()"]/g, "\\$&")}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
  for (const edge of ["right", "left", "bottom", "top"]) {
    const body = rule(`:where([data-enter="${edge}"])`);
    expect(body).toContain("--ui-enter-x:");
    expect(body).toContain("--ui-enter-y:");
  }
  expect(rule(":where([data-enter] [data-enter])")).toContain("--ui-enter-distance: 8px");
});

// Session Info stays drawn while the pane switches chats: the next chat's tasks are the ones its
// list is drawn with, so none of them drops in.
test("switching chats with Session Info open replays none of the next chat's tasks", async () => {
  const container = installDom();
  setHeaderState({ inspector: true });
  setChatDisplay({});
  resetSessionInfoState();
  const process = (id: string, command: string): SessionInfoProcess => ({
    id,
    command,
    startedAt: 1_000,
    state: "running",
  });
  const first: AcpmuxSnapshot = chat([user("Build it", 4), assistant("Done.", 3)]);
  const second: AcpmuxSnapshot = { ...first, sessionId: "other-session" };
  let show: (chat: AcpmuxSnapshot, processes: SessionInfoProcess[]) => void = () => {};
  function Pane() {
    const [state, setState] = useState({
      snapshot: first,
      processes: [process("s1/a", "tsc --watch")],
    });
    show = (snapshot, processes) => setState({ snapshot, processes });
    const inspector = useSessionInfo({
      snapshot: state.snapshot,
      shell: null,
      processes: { processes: state.processes, listed: true },
    });
    return <section className="acpmux-shell">{inspector.panel}</section>;
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane />);
  });
  await act(async () => {
    setSessionInfoSection("tasks", true);
    setSessionInfoOpen(true);
  });
  const rows = () => entering(container, "li.acpmux-session-info-task--command");
  expect(rows()).toEqual(["tsc:-"]);
  await act(async () => show(second, [process("other-session/b", "pytest -x")]));
  expect(rows()).toEqual(["pytest:-"]);
});

// A command only the transcript knew, once the registry lists it, takes the registry's id: it is
// the same command, already in the list, so it does not drop in again.
test("a transcript-only command the registry then lists does not enter again", async () => {
  const container = installDom();
  const transcriptOnly: BackgroundCommand = {
    ...command("call-a", "tsc --watch"),
    toolCallId: "call-a",
  };
  await act(async () => {
    root = createRoot(container);
    root.render(<TasksSection commands={[transcriptOnly]} />);
  });
  const listed: BackgroundCommand = {
    ...command("s1/a", "tsc --watch"),
    toolCallId: "call-a",
    processId: "s1/a",
  };
  await act(async () => root!.render(<TasksSection commands={[listed]} />));
  expect(entering(container, "li.acpmux-session-info-task--command")).toEqual(["tsc:-"]);

  await act(async () => root!.render(<SummaryTasks commands={[transcriptOnly]} />));
  await act(async () => root!.render(<SummaryTasks commands={[listed]} />));
  expect(entering(container, "li.acpmux-summary-task")).toEqual(["tsc:-"]);
});

// A row's entrance plays once while the complete list stays mounted in the scrollable card.
test("the complete list does not replay rows that already entered", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<SummaryTasks commands={[]} />);
  });
  const names = ["bun test", "cargo test", "vite", "pytest -x", "tsc -b", "tsc --watch"];
  const commands = names.map((name, index) => ({
    ...command(`c${index}`, name),
    startedAt: 1_000 + index,
  }));
  await act(async () => root!.render(<SummaryTasks commands={commands} />));
  const rows = () => [...container.querySelectorAll<HTMLElement>("li.acpmux-summary-task")];
  expect(rows().every((row) => row.dataset.enter === "top")).toBe(true);
  for (const row of rows()) await played(row);
  expect(rows()).toHaveLength(6);
  expect(rows().map((row) => row.dataset.enter ?? "-")).toEqual(["-", "-", "-", "-", "-", "-"]);
  expect(rows().map((row) => row.dataset.enter ?? "-")).toEqual(["-", "-", "-", "-", "-", "-"]);
});
