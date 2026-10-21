// l10n-allow-file: test fixtures (sample messages and replies), not shipped UI.
// A reply in place and the discussion after it (IncomingMessageCard.tsx, IncomingMessageThread.tsx,
// messageThreads.ts): the person's sent reply reads under the message it answers, and stays there
// when the row mounts again (scrolled out of the virtualized transcript and back); the other
// agent's answer in the same thread joins that message's thread, under the reply, instead of
// reading as a new message of its own.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { IncomingMessageLine } from "./IncomingMessageCard";
import type { IncomingMessage } from "./incomingMessage";
import type { AcpmuxRow } from "../model";
import strings from "../generated/strings.json";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "requestAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
  "__cmuxPaneStrings",
];

function installDom(): HTMLElement {
  dom ??= new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  if (saved.size === 0) for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    requestAnimationFrame: (callback: () => void) => setTimeout(callback, 0),
    IS_REACT_ACT_ENVIRONMENT: true,
    __cmuxPaneStrings: strings,
  });
  return dom.window.document.getElementById("root")!;
}

async function mount(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

async function unmount() {
  if (root)
    await act(async () => {
      root!.unmount();
    });
  root = undefined;
}

afterEach(async () => {
  await unmount();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/// Opens the message's Reply, types `text` and sends it.
async function reply(container: HTMLElement, text: string) {
  const button = [...container.querySelectorAll<HTMLButtonElement>(".cv-received__reply")].at(-1)!;
  await act(async () => button.click());
  const field = container.querySelector<HTMLTextAreaElement>(".cv-message__reply textarea")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, text);
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  const send = container.querySelector<HTMLButtonElement>(".cv-message__reply .cv-user__edit-button--send")!;
  await act(async () => send.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

const message = (fields: Partial<IncomingMessage> & { text: string }): IncomingMessage => ({
  name: "Grid fix",
  sessionId: "child-3",
  raw: fields.text,
  ...fields,
});

const row = (id: string, at: number, incoming?: IncomingMessage): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: incoming ? "user" : "assistant",
  text: incoming?.text ?? "Merged it.",
  ...(incoming && { incoming: { kind: "message" as const, message: incoming }, untyped: true }),
});

test("a sent reply's text reads under the message it answers, and stays after the row mounts again", async () => {
  const sent: string[] = [];
  const asked = message({ msgId: "m-10", threadId: "m-10", text: "Tests pass. Merge it?" });
  const line = (
    <IncomingMessageLine
      id="row-10"
      message={asked}
      onOpen={() => {}}
      onReply={async (_, text) => {
        sent.push(text);
      }}
    />
  );
  let container = await mount(line);
  await reply(container, "Yes, merge it after the review passes.");
  expect(sent).toEqual(["Yes, merge it after the review passes."]);
  expect(container.textContent).toContain("Yes, merge it after the review passes.");
  // Scrolled out of the virtualized transcript and back: the row mounts again.
  await unmount();
  container = await mount(line);
  expect(container.textContent).toContain("Yes, merge it after the review passes.");
});

test("two messages in one thread read as one card's thread, the reply between them", async () => {
  const { withMessageThreads } = await import("./messageThreads");
  const { IncomingMessageThread } = await import("./IncomingMessageThread");
  const first = row("row-20", 1, message({ msgId: "m-20", threadId: "m-20", text: "Tests pass. Merge it?" }));
  const work = row("row-21", 2);
  const answer = row(
    "row-22",
    3,
    message({ msgId: "m-22", threadId: "m-20", replyTo: "m-21", text: "Merged as #23900." }),
  );
  const draw = (target: AcpmuxRow) => (
    <IncomingMessageThread row={target} onOpen={() => {}} onReply={async () => {}} actions={() => null} />
  );
  // Before the answer: the message alone, and the person replies to it.
  const before = withMessageThreads([first, work]);
  expect(before.map((each) => each.id)).toEqual(["row-20", "row-21"]);
  let container = await mount(draw(before[0]!));
  await reply(container, "Merge it once CI is green.");
  await unmount();
  // The answer in the same thread joins the first message's card, not a row of its own; the
  // agent's work between them stays where it was.
  const after = withMessageThreads([first, work, answer]);
  expect(after.map((each) => each.id)).toEqual(["row-20", "row-21"]);
  container = await mount(draw(after[0]!));
  expect(container.querySelectorAll(".cv-received-thread")).toHaveLength(1);
  const text = container.textContent ?? "";
  const asked = text.indexOf("Tests pass. Merge it?");
  const replied = text.indexOf("Merge it once CI is green.");
  const answered = text.indexOf("Merged as #23900.");
  expect(asked).toBeGreaterThanOrEqual(0);
  expect(replied).toBeGreaterThan(asked);
  expect(answered).toBeGreaterThan(replied);
  // Each message keeps its own line; only the latest takes Reply.
  expect(container.querySelectorAll(".cv-received")).toHaveLength(2);
  expect(container.querySelectorAll(".cv-received__reply")).toHaveLength(1);
  expect(container.querySelectorAll(".cv-received")[1]!.querySelector(".cv-received__reply")).not.toBeNull();
});
