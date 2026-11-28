// l10n-allow-file: test fixture wakeups, not shipped UI.
// Session Info on the page, for a chat on this Mac whose only background task is a wakeup (Leo,
// 2026-11-06: "so-called fallback heartbeat, and it doesn't get highlighted in the same way that the
// other ones do"): the panel reads the loaded calls for the wakeup even though a local chat opens
// its commands' terminals instead, so the wakeup's row is the lit button that shows its call.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { useSessionInfo } from "../src/agent-session/acpmux/session-info/useSessionInfo";
import {
  resetSessionInfoState,
  setSessionInfoOpen,
  setSessionInfoSection,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { activity, assistant, chat, user } from "../src/gallery/fixtures/acpmux";
import { settleReact } from "./support/domTeardown";

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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a local chat's lone wakeup is a button that shows the call that made it", async () => {
  const container = installDom();
  setHeaderState({ inspector: true });
  setChatDisplay({});
  resetSessionInfoState();
  const shown: string[] = [];
  const wakeup = activity(
    [
      {
        kind: "tool",
        text: "ScheduleWakeup",
        tool: {
          id: "toolu_heartbeat",
          title: "ScheduleWakeup",
          kind: "other",
          status: "completed",
          inputSummary: JSON.stringify({ reason: "Fallback heartbeat", delaySeconds: 1200 }),
          startedAt: Date.now() - 60_000,
        },
      },
    ],
    3,
  );
  const snapshot: AcpmuxSnapshot = chat([user("Watch the review", 4), wakeup, assistant("Waiting.", 3)]);
  function Pane() {
    const sessionInfo = useSessionInfo({
      snapshot,
      shell: null,
      processes: { processes: [], listed: true },
      onShowCall: (id) => {
        shown.push(id);
        return true;
      },
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
  const row = container.querySelector<HTMLElement>('li.acpmux-session-info-task[data-kind="wakeup"]');
  expect(row?.textContent).toContain("Fallback heartbeat");
  const button = row!.querySelector<HTMLButtonElement>(":scope > button.acpmux-session-info-task__open");
  expect(button).not.toBeNull();
  await act(async () => button!.click());
  expect(shown).toEqual(["toolu_heartbeat"]);
});
