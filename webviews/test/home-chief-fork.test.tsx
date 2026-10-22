// "Fork to New Chief" (user 9935): a right-click on any message of a conversation with one of this
// Mac's Chiefs offers it; it sends ONE `chief.profile.create` through the host's relay (the person's
// click) with `fork {chief, conversation, seq}` and the default name "<Chief> fork", then opens the
// new Chief's direct message. The new Chief's record says where it came from (`forked_from`), and its
// chat shows that line. The Cloud Chief's conversations offer no fork (its memory is the hosted brain's).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { forkFields, forkName, forkOriginText, forkTarget } from "../src/pages/home-channels/chiefFork";
import { chief } from "../src/pages/home-channels/daemonPeople";
import table from "../src/pages/home-channels/generated/strings.json";
import { MessageRow } from "../src/pages/home-channels/MessageRow";
import { HomeSheets } from "../src/pages/home-channels/sheets";
import { HomeOps, type HomeConversation, type HomeMessage } from "../src/pages/home-channels/types";
import { createStrings } from "../src/pages/shared/i18n";
import type { PageClient } from "../src/pages/shared/pageClient";

const strings = createStrings(table, ["en"]);

const SCOUT = {
  id: "agent_scout",
  display_name: "Scout",
  role: "Researcher",
  personality: "",
  instructions: "",
  tools: ["chiefs", "spawn", "tell"],
  harnesses: [],
  self_edit: ["avatar"],
  is_default: false,
  rev: 1,
  created_at: "2026-10-10T09:00:00Z",
  avatar: null,
  locked: false,
};
const OPS = { ...SCOUT, id: "agent_ops", display_name: "Ops" };

const message = (author: string, seq = 4): HomeMessage => ({
  id: `m${seq}`,
  conversation: "conv_dm",
  seq,
  author,
  createdAt: 0,
  retracted: false,
  parts: [{ type: "text", text: "look into X", mentions: [] }] as never,
  reactions: [],
});

const conversation = (ids: string[], owner: "local" | "cloud" = "local"): HomeConversation =>
  ({
    id: "conv_dm",
    owner,
    title: "",
    kind: ids.length > 1 ? "group" : "chief",
    participants: [
      { id: "user_local", kind: "human", name: "Me", chief: false },
      ...ids.map((id) => ({ id, kind: "agent", name: id, chief: true })),
    ],
    lastSeq: 9,
    rev: 1,
    updatedAt: 0,
    unread: 0,
  }) as never;

const chiefs = new Map([
  ["agent_scout", chief(SCOUT)],
  ["agent_ops", chief(OPS)],
]);

test("a message forks the Chief of its conversation, or the Chief that wrote it", () => {
  expect(forkTarget(conversation(["agent_scout"]), message("user_local"), chiefs)?.id).toBe("agent_scout");
  expect(forkTarget(conversation(["agent_scout"]), message("agent_scout"), chiefs)?.id).toBe("agent_scout");
  // Two Chiefs: only a Chief's own message says whose memory it is.
  const both = conversation(["agent_scout", "agent_ops"]);
  expect(forkTarget(both, message("agent_ops"), chiefs)?.id).toBe("agent_ops");
  expect(forkTarget(both, message("user_local"), chiefs)).toBeUndefined();
  // No fork of a retracted message, of a conversation with no Chief, or of the Cloud Chief's.
  expect(
    forkTarget(conversation(["agent_scout"]), { ...message("user_local"), retracted: true }, chiefs),
  ).toBeUndefined();
  expect(forkTarget(conversation([]), message("user_local"), chiefs)).toBeUndefined();
  expect(forkTarget(conversation(["agent_scout"], "cloud"), message("user_local"), chiefs)).toBeUndefined();
});

test("a fork's create names its source and message, and defaults the name to '<Chief> fork'", () => {
  const scout = chiefs.get("agent_scout")!;
  expect(forkFields(scout, message("user_local", 7), strings)).toEqual({
    display_name: "Scout fork",
    fork: { chief: "agent_scout", conversation: "conv_dm", seq: 7 },
  });
  const long = chief({ ...SCOUT, display_name: "n".repeat(100) });
  expect(Array.from(forkName(long, strings)).length).toBeLessThanOrEqual(100);
});

test("a forked Chief's record and chat say where its memory came from", () => {
  const forked = chief({
    ...SCOUT,
    id: "agent_fork",
    display_name: "Scout fork",
    forked_from: {
      chief: "agent_scout",
      name: "Scout",
      conversation: "conv_dm",
      seq: 7,
      cut: 40,
      by: "person",
      at: "2026-10-22T01:00:00.000Z",
    },
  });
  expect(forked.forkedFrom).toEqual({
    chief: "agent_scout",
    name: "Scout",
    conversation: "conv_dm",
    seq: 7,
    by: "person",
    at: "2026-10-22T01:00:00.000Z",
  });
  expect(forkOriginText(forked, strings)).toBe(strings.format("fork.origin.message", "Scout", "7"));
  const own = chief({
    ...SCOUT,
    forked_from: { chief: "agent_scout", name: "Scout", cut: 3, by: "agent_scout", at: "x" },
  });
  expect(forkOriginText(own, strings)).toBe(strings.format("fork.origin.now", "Scout"));
  expect(forkOriginText(chiefs.get("agent_scout"), strings)).toBeUndefined();
});

test("Fork to New Chief sends one create through the host and opens the new Chief's chat", async () => {
  const sent: { op: string; params: Record<string, unknown>; via: string }[] = [];
  const made = {
    ...SCOUT,
    id: "agent_new",
    display_name: "Scout fork",
    forked_from: {
      chief: "agent_scout",
      name: "Scout",
      conversation: "conv_dm",
      seq: 4,
      cut: 12,
      by: "person",
      at: "t",
    },
  };
  const client = (via: string): PageClient => ({
    call: async <R,>(op: string, params: unknown) => {
      sent.push({ op, params: params as Record<string, unknown>, via });
      if (op === HomeOps.capabilities) return { start: true, invite: true, chiefs: true } as R;
      if (op === HomeOps.chiefs) return { chiefs: [chief(SCOUT)] } as R;
      if (op === "cmux.chief.profile.list") return { chiefs: [SCOUT] } as R;
      if (op === "cmux.chief.profile.create") return { value: made } as R;
      if (op === HomeOps.startConversation) return { conversation: "conv_new" } as R;
      return {} as R;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  });
  const opened: string[] = [];
  const sheets = new HomeSheets(client("page"), client("host"), {
    open: async (id) => {
      opened.push(id);
    },
    fail: (why) => {
      throw new Error(why);
    },
  });
  await sheets.start();
  await new Promise((resolve) => setTimeout(resolve, 0));
  sent.length = 0;
  const scout = sheets.getSnapshot().chiefs.get("agent_scout")!;
  const result = await sheets.forkChief(forkFields(scout, message("user_local"), strings));
  expect(result?.forkedFrom?.chief).toBe("agent_scout");
  const creates = sent.filter((s) => s.op === "cmux.chief.profile.create");
  expect(creates.length).toBe(1);
  expect(creates[0]!.via).toBe("host");
  expect(creates[0]!.params).toMatchObject({
    display_name: "Scout fork",
    fork: { chief: "agent_scout", conversation: "conv_dm", seq: 4 },
  });
  expect(sent.find((s) => s.op === HomeOps.startConversation)?.params).toMatchObject({ participants: ["agent_new"] });
  expect(opened).toEqual(["conv_new"]);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a right-click on a message offers Fork to New Chief, and choosing it runs the fork", async () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "MouseEvent",
    "KeyboardEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  const forked: HomeMessage[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <MessageRow
        message={message("agent_scout")}
        head
        people={new Map()}
        me="user_local"
        strings={strings}
        timeFormat={new Intl.DateTimeFormat("en", { timeStyle: "short" })}
        editing={false}
        onReact={() => {}}
        fork={(m) => ({ label: strings.t("action.forkToNewChief"), run: () => forked.push(m) })}
      />,
    );
  });
  const text = [...container.querySelectorAll<HTMLElement>("p, span, div")].find(
    (n) => n.textContent === "look into X",
  )!;
  await act(async () =>
    text.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 })),
  );
  const items = [...document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')];
  const fork = items.find((item) => item.textContent === strings.t("action.forkToNewChief"));
  expect(fork).toBeDefined();
  await act(async () => fork!.click());
  expect(forked.map((m) => m.seq)).toEqual([4]);
});
