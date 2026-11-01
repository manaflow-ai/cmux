// l10n-allow-file: test fixture labels, not shipped UI.
// The chat menu's Transcript view (conversation/transcriptView.ts): Normal keeps today's defaults,
// Thinking opens thoughts, Verbose also opens tool output; each chat keeps its own view, a chat
// with none follows `agentPane.display.transcriptView`, and a row reads the view once per render
// from context, so a streamed update does no new work.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, memo } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import {
  resetTranscriptDisclosure,
  TranscriptDisclosureProvider,
  useTranscriptDisclosure,
  useTranscriptViewContext,
  viewChat,
} from "../src/agent-session/acpmux/conversation/transcriptDisclosure";
import {
  makeTranscriptViewDefault,
  resetTranscriptViews,
  setTranscriptView,
  transcriptViewOf,
} from "../src/agent-session/acpmux/conversation/transcriptView";
import { chatDisplayValues, setChatDisplay, TRANSCRIPT_VIEW_KEY } from "../src/agent-session/acpmux/chatDisplay";
import { transcriptViewRow } from "../src/agent-session/acpmux/header/transcriptViewRow";
import { translate } from "../src/agent-session/acpmux/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let renders = 0;

/// A command row's disclosure: closed by default, open in Verbose.
function Command({ id }: { id: string }) {
  const [open, setOpen] = useTranscriptDisclosure(`command:${id}`, false, true);
  renders += 1;
  return (
    <button type="button" data-id={id} aria-expanded={open} onClick={() => setOpen((current) => !current)}>
      {id}
    </button>
  );
}

/// A thought's open default as ThoughtRow reads it.
function Thought() {
  const view = useTranscriptViewContext();
  return <output data-thought={view === "normal" ? "folded" : "open"} />;
}

function render(sessionId: string, streamed = 0) {
  act(() => {
    root ??= createRoot(container);
    root.render(
      <TranscriptDisclosureProvider sessionId={sessionId}>
        <Command id="tool-1" />
        <Thought />
        <output data-streamed={streamed} />
      </TranscriptDisclosureProvider>,
    );
  });
}

const command = () => container.querySelector<HTMLButtonElement>('[data-id="tool-1"]')!;
const thought = () => container.querySelector("[data-thought]")!.getAttribute("data-thought");

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "localStorage", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  resetTranscriptDisclosure();
  resetTranscriptViews();
  setChatDisplay({});
  renders = 0;
  container = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  resetTranscriptViews();
  setChatDisplay({});
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

// The views from the real chat menu on a finished turn: agent-pane-transcript-view.test.ts.

test("a reader's toggle belongs to the view it was made in", () => {
  render("chat-a");
  act(() => command().click());
  expect(command().getAttribute("aria-expanded")).toBe("true");
  // Verbose starts from its own defaults, and closing a row there leaves Normal's choice alone.
  act(() => setTranscriptView("chat-a", "verbose"));
  act(() => command().click());
  expect(command().getAttribute("aria-expanded")).toBe("false");
  act(() => setTranscriptView("chat-a", "normal"));
  expect(command().getAttribute("aria-expanded")).toBe("true");
});

test("each chat keeps its own view; a chat with none follows the default setting", () => {
  act(() => setTranscriptView("chat-a", "verbose"));
  expect(transcriptViewOf("chat-a")).toBe("verbose");
  expect(transcriptViewOf("chat-b")).toBe("normal");
  expect(JSON.parse(dom!.window.localStorage.getItem("cmux.acpmux.transcriptView")!)).toEqual({ "chat-a": "verbose" });
  setChatDisplay({ [TRANSCRIPT_VIEW_KEY]: "thinking" });
  expect(transcriptViewOf("chat-b")).toBe("thinking");
  render("chat-b");
  expect(thought()).toBe("open");
  // A value the page does not know reads as Normal.
  act(() => setChatDisplay({ [TRANSCRIPT_VIEW_KEY]: "loud" }));
  expect(thought()).toBe("folded");
});

test("Make … the default writes the setting and the chat follows it", () => {
  act(() => setTranscriptView("chat-a", "verbose"));
  act(() => makeTranscriptViewDefault("chat-a", "verbose"));
  expect(chatDisplayValues()[TRANSCRIPT_VIEW_KEY]).toBe("verbose");
  expect(transcriptViewOf("chat-a")).toBe("verbose");
  expect(transcriptViewOf("chat-z")).toBe("verbose");
  // Normal is the setting's default: making it the default removes the key.
  act(() => makeTranscriptViewDefault("chat-a", "normal"));
  expect(TRANSCRIPT_VIEW_KEY in chatDisplayValues()).toBe(false);
});

test("the menu row checks the chat's view and offers Make … the default only off the default", () => {
  const row = transcriptViewRow("chat-a", translate)!;
  const children = row.children!;
  const checked = children.filter((child) => child.checked).map((child) => child.key);
  expect(checked).toEqual(["transcriptView.normal"]);
  const last = children.at(-1)!;
  expect(last.disabled).toBe(true);
  expect(last.separatorBefore).toBe(true);
  act(() => setTranscriptView("chat-a", "thinking"));
  const after = transcriptViewRow("chat-a", translate)!.children!;
  const make = after.at(-1)!;
  expect(make.label).toBe("Make Thinking the default");
  expect(make.disabled).toBe(false);
  expect(transcriptViewRow(undefined, translate)).toBeUndefined();
});

test("a chat's own view that equals the default can still be cleared, so it follows later defaults", () => {
  // Picking Normal (the default) by hand makes it the chat's own view.
  act(() => setTranscriptView("chat-a", "normal"));
  const make = transcriptViewRow("chat-a", translate)!.children!.at(-1)!;
  expect(make.label).toBe("Make Normal the default");
  // Enabled: it is the only way to drop the chat's own view and follow the setting again.
  expect(make.disabled).toBe(false);
  act(() => make.onSelect());
  expect(JSON.parse(dom!.window.localStorage.getItem("cmux.acpmux.transcriptView") ?? "{}")).toEqual({});
  // The chat now follows a later default.
  act(() => setChatDisplay({ [TRANSCRIPT_VIEW_KEY]: "verbose" }));
  expect(transcriptViewOf("chat-a")).toBe("verbose");
  // Following the default with no view of its own, there is nothing to make or clear.
  expect(transcriptViewRow("chat-a", translate)!.children!.at(-1)!.disabled).toBe(true);
});

test("a streamed update renders a row once, as before; only a switch adds a render", () => {
  const Row = memo(Command);
  function Rows({ tokens }: { tokens: number }) {
    return (
      <TranscriptDisclosureProvider sessionId="chat-a">
        <Row id="tool-1" />
        <output data-streamed={tokens} />
      </TranscriptDisclosureProvider>
    );
  }
  act(() => {
    root = createRoot(container);
    root.render(<Rows tokens={0} />);
  });
  const first = renders;
  for (let token = 1; token <= 200; token += 1) act(() => root!.render(<Rows tokens={token} />));
  // The memoized row never draws for a token: the view and its disclosure are unchanged.
  expect(renders - first).toBe(0);
  act(() => setTranscriptView("chat-a", "verbose"));
  expect(renders - first).toBe(1);
});

test("a subagent's transcript and a replay follow their chat's view", () => {
  expect(viewChat("chat-a")).toBe("chat-a");
  expect(viewChat("chat-a:subagent:task-1")).toBe("chat-a");
  expect(viewChat("replay:chat-a")).toBe("chat-a");
  expect(viewChat(undefined)).toBeUndefined();
});

test("two panes' choices both survive: each write reads storage fresh, and a storage event refreshes", () => {
  act(() => setTranscriptView("chat-a", "thinking"));
  // Another pane (its own copy of the map) sets chat-b's view and writes storage.
  const other = JSON.parse(dom!.window.localStorage.getItem("cmux.acpmux.transcriptView")!);
  dom!.window.localStorage.setItem("cmux.acpmux.transcriptView", JSON.stringify({ ...other, "chat-b": "verbose" }));
  // This pane, before hearing of it, sets chat-c: chat-b's choice must stay.
  act(() => setTranscriptView("chat-c", "verbose"));
  expect(JSON.parse(dom!.window.localStorage.getItem("cmux.acpmux.transcriptView")!)).toEqual({
    "chat-a": "thinking",
    "chat-b": "verbose",
    "chat-c": "verbose",
  });
  // A storage event from the other pane updates what this pane shows.
  dom!.window.localStorage.setItem(
    "cmux.acpmux.transcriptView",
    JSON.stringify({ "chat-a": "thinking", "chat-b": "normal", "chat-c": "verbose" }),
  );
  // The store listens on the page's global (transcriptView.ts), where a storage event arrives.
  act(() => {
    const event = Object.assign(new Event("storage"), { key: "cmux.acpmux.transcriptView" });
    globalThis.dispatchEvent(event);
  });
  expect(transcriptViewOf("chat-b")).toBe("normal");
});
