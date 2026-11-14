// l10n-allow-file: test fixtures (messages between agents).
// The hover of a folded group of received messages ("Received 7 messages"; MessageGroupHover.tsx).
// Leo, 2026-11-07: "the hover preview when you receive a lot of messages, this is not useful." It
// reads who sent, how many each, and the newest message in full, not a stack of rows cut to two
// lines each.
// Trace-ID: ask-2328a045b7.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import {
  MessageGroupHover,
  hoverMessages,
  inboxHover,
} from "../src/agent-session/acpmux/conversation/MessageGroupHover";
import type { IncomingMessage } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

const one = (name: string, text: string, extra: Partial<IncomingMessage> = {}): IncomingMessage => ({
  name,
  text,
  raw: "",
  ...extra,
});

const REPORT = [
  "**#37534 is green** at `64d6b1b`.",
  "",
  "- the canary stays on the build box",
  "- the cap counts each host once",
  "- the review is a SHIP",
  "Landing it pinned once the base-only reds are confirmed.",
].join("\n");

test("the hover shows the newest message whole, then each other sender once with their count", async () => {
  // Oldest first, as the group holds them: lane-a three times, lane-b twice, lane-c once, then the
  // newest from lane-d.
  const list = hoverMessages([
    one("vm-1/lane-a", "a one"),
    one("vm-1/lane-b", "b one"),
    one("vm-1/lane-a", "a two"),
    one("vm-1/lane-c", "c one", { unverified: true }),
    one("vm-1/lane-b", "b two"),
    one("vm-1/lane-a", "a three"),
    one("vm-1/lane-d", REPORT),
  ]);
  const container = await render(<MessageGroupHover list={list} />);
  const newest = container.querySelector(".cv-group-hover__newest");
  expect(newest?.querySelector(".cv-group-hover__name")?.textContent).toBe("lane-d");
  // The whole message, every line, its Markdown marks out: never cut to its first two lines.
  const body = newest?.querySelector(".cv-group-hover__body")?.textContent ?? "";
  expect(body).toContain("#37534 is green at 64d6b1b.");
  expect(body).toContain("the review is a SHIP");
  expect(body).toContain("Landing it pinned once the base-only reds are confirmed.");
  expect(body).not.toContain("**");
  // Its lines stay lines.
  expect(body.split("\n").length).toBeGreaterThanOrEqual(4);
  // The others: each sender once, newest sender first, with how many they sent; no rows of text.
  const senders = [...container.querySelectorAll(".cv-group-hover__sender")];
  expect(senders.map((s) => s.querySelector(".cv-group-hover__name")?.textContent)).toEqual([
    "lane-a",
    "lane-b",
    "lane-c",
  ]);
  expect(senders.map((s) => s.querySelector(".cv-group-hover__count")?.textContent ?? "")).toEqual(["3", "2", ""]);
  expect(senders[2]?.querySelector(".cv-unverified")).not.toBeNull();
  expect(container.textContent).not.toContain("a one");
  expect(container.querySelector(".cv-group-hover__item")).toBeNull();
  expect(container.querySelector(".cv-group-hover__more")).toBeNull();
});

test("the newest sender's earlier messages count under their own name", async () => {
  const list = hoverMessages([one("vm-1/lane-a", "first"), one("vm-1/lane-b", "b"), one("vm-1/lane-a", "newest")]);
  const container = await render(<MessageGroupHover list={list} />);
  expect(container.querySelector(".cv-group-hover__body")?.textContent).toBe("newest");
  const senders = [...container.querySelectorAll(".cv-group-hover__sender")];
  // Newest first: lane-b wrote after lane-a's first.
  expect(senders.map((s) => s.textContent)).toEqual(["lane-b", "lane-a"]);
});

test("one message alone: the message, no list under it", async () => {
  const container = await render(<MessageGroupHover list={hoverMessages([one("vm-1/lane-a", "only")])} />);
  expect(container.querySelector(".cv-group-hover__body")?.textContent).toBe("only");
  expect(container.querySelector(".cv-group-hover__senders")).toBeNull();
});

test("past four other senders, the rest is one +N more that counts their messages", async () => {
  const names = ["s1", "s2", "s3", "s4", "s5", "s6"];
  // s1..s6 once each, s6 twice more, then the newest from s0.
  const list = hoverMessages([
    ...names.map((name) => one(`vm/${name}`, name)),
    one("vm/s6", "again"),
    one("vm/s6", "again"),
    one("vm/s0", "newest"),
  ]);
  const container = await render(<MessageGroupHover list={list} />);
  const senders = [...container.querySelectorAll(".cv-group-hover__sender")];
  expect(senders).toHaveLength(4);
  // s6 (newest of the others, 3 messages), then s5, s4, s3: the rest is s2 and s1, two messages.
  expect(senders[0]?.textContent).toBe("s63");
  expect(container.querySelector(".cv-group-hover__more")?.textContent).toBe("+2 more");
});

test("an inbox thread that held only its preview counts its whole thread under its sender", async () => {
  const list = inboxHover([
    {
      threadId: "pr:1",
      label: "#1",
      from: ["vm/lane-b"],
      count: 4,
      preview: "newest from b",
      blocker: false,
      promptIds: ["b1", "b2", "b3", "b4"],
    },
    {
      threadId: "pr:2",
      label: "#2",
      from: ["vm/lane-a"],
      count: 1,
      preview: "",
      blocker: false,
      promptIds: ["a1"],
      messages: [{ promptId: "a1", from: "vm/lane-a", text: "timed from a", at: 40 }],
    },
  ]);
  expect(list.total).toBe(5);
  const container = await render(<MessageGroupHover list={list} />);
  expect(container.querySelector(".cv-group-hover__body")?.textContent).toBe("timed from a");
  const senders = [...container.querySelectorAll(".cv-group-hover__sender")];
  expect(senders.map((s) => s.textContent)).toEqual(["lane-b4"]);
});

// The wall in Leo's screenshot: every sender as "<lane> (self-declared, unauthenticated)".
test("names read short and plain, and the broker's label never shows", async () => {
  const suffix = "(self-declared, unauthenticated)";
  const relayed = (body: string, id: string, from: string) =>
    [
      `[message ${id} from ${from} (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message ${id}]"]`,
      body,
      `[end of message ${id}]`,
    ].join("\n");
  const list = hoverMessages(
    ["cloud-client-rust", "palette-ranker-one", "pr-latency", "chat-targets"].map((name, index) =>
      one(`gcp-agent-lane-3/${name} ${suffix}`, relayed(`${name} report\nsecond line`, `abcd000${index}`, name), {
        unverified: true,
      }),
    ),
  );
  const container = await render(<MessageGroupHover list={list} />);
  const text = container.textContent ?? "";
  expect(text).not.toContain("self-declared");
  expect(text).not.toContain("[message");
  expect(text).not.toContain("gcp-agent-lane-3/");
  expect(container.querySelector(".cv-group-hover__body")?.textContent).toBe("chat-targets report\nsecond line");
  expect(container.querySelectorAll(".cv-unverified").length).toBe(4);
});
