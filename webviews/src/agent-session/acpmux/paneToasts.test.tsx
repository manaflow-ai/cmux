// l10n-allow-file: test fixtures.
// Leo, 2026-11-07, after a click on a sender with no chat put two identical lines in the
// transcript: transient feedback goes to the toast stack, never the transcript, and the same
// notice twice is one toast with a count.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createNoticeQueue } from "../../ui/NoticeStack";
import type { AcpmuxActivity } from "./model";
import { resetSessionRefs, senderRef, setSessionRefResolver } from "./conversation/sessionRefs";
import { resetTranscriptDisclosure } from "./conversation/transcriptDisclosureModel";
import { WhoElseCard } from "./conversation/WhoElseCard";
import { whoElseCall, WHO_ELSE_SCHEMA } from "./conversation/whoElseCalls";
import { paneNotices } from "./paneToasts";
import { SubsessionContext, SubsessionStore } from "./subagents/subsessions";
import { settleReact } from "../../../test/support/domTeardown";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const ANSWER = {
  schema: WHO_ELSE_SCHEMA,
  query: { files: ["src/a.rs"], fileCount: 1 },
  sessions: [
    {
      sessionId: "s-peer",
      name: "mux-rs",
      ref: "build-box/mux-rs",
      host: "build-box",
      harness: "codex",
      status: "idle",
      live: true,
      agoMs: 60_000,
      filesInCommon: 1,
      editedInCommon: 0,
      files: [{ path: "src/a.rs", edited: false }],
      pullRequests: [],
      sameWorktree: false,
      sameBranch: false,
      topicWords: [],
    },
  ],
  more: 0,
  unreached: [],
};

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  setSessionRefResolver(undefined);
  resetSessionRefs();
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
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

test("a click on a sender with no chat adds no transcript line; a second click counts on the same toast", async () => {
  setSessionRefResolver(async () => null);
  const lines: string[] = [];
  const toasts = createNoticeQueue();
  const notices = paneNotices({ transcript: () => ({ notice: (text: string) => lines.push(text) }), toasts });
  const item: AcpmuxActivity = {
    kind: "tool",
    text: "mcp__acpmux__who_else",
    tool: { id: "w", status: "completed", title: "mcp__acpmux__who_else", output: JSON.stringify(ANSWER) } as Tool,
  };
  const page = await render(
    <SubsessionContext.Provider
      value={{ store: new SubsessionStore(), open: () => undefined, senderMissing: notices.senderMissing }}
    >
      <WhoElseCard item={item} call={whoElseCall(item)!} />
    </SubsessionContext.Provider>,
  );
  const chip = page.querySelector<HTMLButtonElement>(".cv-agent-tag.is-open")!;
  await act(async () => chip.click());
  expect(lines).toEqual([]);
  expect(toasts.snapshot().map((entry) => [entry.spec.message, entry.count])).toEqual([
    ["Can't find build-box/mux-rs's chat", 1],
  ]);
  await act(async () => chip.click());
  expect(lines).toEqual([]);
  expect(toasts.snapshot().map((entry) => [entry.spec.message, entry.count])).toEqual([
    ["Can't find build-box/mux-rs's chat", 2],
  ]);
});

test("a sender that named itself is looked up without acpmux's unauthenticated label", () => {
  expect(senderRef("build-box/mux-rs (self-declared, unauthenticated)")).toBe("build-box/mux-rs");
  expect(senderRef(" mux-rs ")).toBe("mux-rs");
  // Only the label at the end goes.
  expect(senderRef("notes (draft)")).toBe("notes (draft)");
});

// Lawrence, 2026-11-13: "we need to improve all our toasts/prompts, make a swift playground for me to
// pick my favorite". The pane's feedback toasts are the app's native toasts when a native host draws
// the pane, so the style picked in the Toast Playground covers them too; the page's own stack draws
// them only without a host (the browser dev page) or when the host refuses.
test("with a native host, feedback and failures are native toasts and the page draws none", async () => {
  const posted: Array<{ message: string; tone: string; group: string }> = [];
  const toasts = createNoticeQueue();
  const notices = paneNotices({
    transcript: () => undefined,
    toasts,
    native: async (toast) => {
      posted.push(toast);
      return true;
    },
  });
  notices.transient("Copied the link", "copy");
  notices.failed("Could not open the chat");
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(posted).toEqual([
    { message: "Copied the link", tone: "neutral", group: "copy" },
    { message: "Could not open the chat", tone: "error", group: "feedback" },
  ]);
  expect(toasts.snapshot()).toEqual([]);
});

test("a host that refuses the toast leaves it to the page's own stack", async () => {
  const toasts = createNoticeQueue();
  const notices = paneNotices({ transcript: () => undefined, toasts, native: async () => false });
  notices.transient("Copied the link");
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(toasts.snapshot().map((entry) => entry.spec.message)).toEqual(["Copied the link"]);
});
