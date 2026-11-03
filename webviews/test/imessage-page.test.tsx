// The Messages mirror page (cmux-page://cmux.imessage/) over the mock `cmux.imessage.*` provider:
// each mirror state shows its own card (off, no Full Disk Access, no database, error, and a daemon
// that does not know the ops yet is the error card, never a blank page); a ready page lists the
// threads and opens the newest; scrolling up reads the page before the oldest bubble; a live
// `cmux.imessage.changed` re-reads the list and merges the new message into the open conversation
// without dropping the older pages; the conversation's rows put day lines, sender handles in groups
// and bubble runs in the right places.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../src/pages/shared/i18n";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";
import table from "../src/pages/imessage/generated/strings.json";
import { ImessagePage } from "../src/pages/imessage/ImessagePage";
import { MockImessageProvider } from "../src/pages/imessage/mockProvider";
import {
  attachmentName,
  conversationRows,
  initials,
  mergeMessages,
  normalizeMessage,
  relativeKind,
} from "../src/pages/imessage/model";
import { ImessageStore, errorPhase, statusPhase } from "../src/pages/imessage/store";
import { ImessageOps, MESSAGE_PAGE, type Message } from "../src/pages/imessage/types";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/** 2026-10-12T12:00Z. */
const NOON = Date.UTC(2026, 9, 12, 12);
const strings = createStrings(table, ["en"]);
const clock = { now: () => NOON, offsetMinutes: 0 };

function message(rowid: number, patch: Partial<Message> = {}): Message {
  return {
    rowid,
    guid: `g-${rowid}`,
    chat_id: 1,
    sender: "+15550100",
    is_from_me: false,
    date_ms: NOON - (100 - rowid) * 60_000,
    text: `m${rowid}`,
    attachments: [],
    ...patch,
  };
}

async function render(store: ImessageStore): Promise<{ root: Root; text: () => string }> {
  const root = createRoot(host);
  await act(async () => {
    root.render(<ImessagePage store={store} strings={strings} clock={clock} />);
    await store.start();
  });
  return { root, text: () => host.textContent ?? "" };
}

async function settle(): Promise<void> {
  for (let i = 0; i < 5; i++) await act(async () => await Promise.resolve());
}

test("each status answer is its own page state", () => {
  expect(statusPhase({ enabled: false, access: "ok" })).toBe("off");
  expect(statusPhase({ enabled: true, access: "off" })).toBe("off");
  expect(statusPhase({ enabled: true, access: "ok" })).toBe("ready");
  expect(statusPhase({ enabled: true, access: "not_permitted" })).toBe("not_permitted");
  expect(statusPhase({ enabled: true, access: "missing" })).toBe("missing");
  expect(statusPhase({ enabled: true, access: "schema" })).toBe("error");
  expect(statusPhase({ enabled: true, access: "error" })).toBe("error");
  expect(statusPhase(null)).toBe("error");
});

test("the list ops' refusals map to states, with or without the relay's cmux. prefix", () => {
  expect(errorPhase(pageError("cmux.imessage_disabled", "off"))).toBe("off");
  expect(errorPhase(pageError("imessage_not_permitted", "no access"))).toBe("not_permitted");
  expect(errorPhase(pageError("cmux.imessage_unavailable", "gone"))).toBe("error");
  expect(errorPhase(pageError("cmux.protocol.unknown_op", "imessage.status"))).toBe("error");
  expect(errorPhase(new Error("boom"))).toBe("error");
});

test("off is the default state: it says where the toggle is and that nothing leaves the Mac", async () => {
  const provider = new MockImessageProvider("off", NOON);
  const store = new ImessageStore(provider);
  const { root, text } = await render(store);
  expect(store.getSnapshot().phase).toBe("off");
  expect(text()).toContain(strings.t("imessage.off.title"));
  expect(text()).toContain("Mirror Messages (local only)");
  expect(text()).toContain(strings.t("imessage.off.privacy"));
  // Off reads nothing but the status.
  expect(provider.calls.map((call) => call.op)).toEqual([ImessageOps.status]);
  const button = [...host.querySelectorAll("button")].find((b) => b.textContent === strings.t("imessage.off.action"))!;
  await act(async () => button.click());
  expect(provider.calls.at(-1)).toEqual({
    op: "cmux.app.action.run",
    params: { action: "openSettings", args: { setting: "imessage.enabled" } },
  });
  act(() => root.unmount());
});

test("without Full Disk Access the page offers that pane and says the grant goes to cmux", async () => {
  const provider = new MockImessageProvider("not_permitted", NOON);
  const store = new ImessageStore(provider);
  const { root, text } = await render(store);
  expect(store.getSnapshot().phase).toBe("not_permitted");
  expect(text()).toContain(strings.t("imessage.access.title"));
  expect(text()).toContain(strings.t("imessage.access.note"));
  const button = [...host.querySelectorAll("button")].find(
    (b) => b.textContent === strings.t("imessage.access.action"),
  )!;
  await act(async () => button.click());
  expect(provider.calls.at(-1)?.op).toBe(ImessageOps.openFullDiskAccess);
  act(() => root.unmount());
});

test("missing, error and a daemon without the ops each show a card, never a blank page", async () => {
  for (const [kind, title] of [
    ["missing", "imessage.missing.title"],
    ["error", "imessage.error.title"],
    ["unknown", "imessage.error.title"],
    ["empty", "imessage.empty.title"],
  ] as const) {
    const store = new ImessageStore(new MockImessageProvider(kind, NOON));
    const { root, text } = await render(store);
    expect(text()).toContain(strings.t(title));
    act(() => root.unmount());
  }
});

test("no host at all says so", async () => {
  const store = new ImessageStore(null);
  const { root, text } = await render(store);
  expect(store.getSnapshot().phase).toBe("unavailable");
  expect(text()).toContain(strings.t("imessage.unavailable"));
  act(() => root.unmount());
});

test("a ready page lists the threads, newest first, and opens the newest", async () => {
  const store = new ImessageStore(new MockImessageProvider("ready", NOON));
  const { root, text } = await render(store);
  await settle();
  const snapshot = store.getSnapshot();
  expect(snapshot.phase).toBe("ready");
  expect(snapshot.threads.map((t) => t.chat_id)).toEqual([7, 11, 4, 2]);
  expect(snapshot.selected).toBe(7);
  expect(snapshot.conversation?.chatId).toBe(7);
  expect(snapshot.conversation?.messages.at(-1)?.text).toBe("Be right there");
  // The group's marker and title, the 1:1's bubbles, mine on the trailing side.
  expect(host.querySelector(".im-group-mark")).not.toBeNull();
  expect(text()).toContain("Weekend hike");
  expect(host.querySelectorAll(".im-message.mine").length).toBeGreaterThan(0);
  expect(host.querySelector(".im-attachment-name")?.textContent).toBe("table.heic");
  act(() => root.unmount());
});

test("selecting a group shows each sender's handle over their run", async () => {
  const store = new ImessageStore(new MockImessageProvider("ready", NOON));
  const { root } = await render(store);
  await settle();
  await act(async () => await store.select(11));
  const senders = [...host.querySelectorAll(".im-sender")].map((node) => node.textContent);
  expect(senders.length).toBeGreaterThan(2);
  expect(senders).toContain("sam.rivera@example.com");
  act(() => root.unmount());
});

test("scrolling up reads the page before the oldest bubble and keeps the loaded ones", async () => {
  const provider = new MockImessageProvider("ready", NOON, { long: true });
  const store = new ImessageStore(provider);
  await store.start();
  await store.select(30);
  const first = store.getSnapshot().conversation!;
  expect(first.messages.length).toBe(MESSAGE_PAGE);
  expect(first.hasOlder).toBe(true);
  const oldest = first.messages[0]!.rowid;
  await store.loadOlder();
  const second = store.getSnapshot().conversation!;
  expect(provider.calls.at(-1)?.params).toEqual({ chat_id: 30, before_rowid: oldest, limit: MESSAGE_PAGE });
  expect(second.messages.length).toBe(MESSAGE_PAGE * 2);
  expect(second.messages[MESSAGE_PAGE]!.rowid).toBe(oldest);
  await store.loadOlder();
  const third = store.getSnapshot().conversation!;
  expect(third.messages.length).toBe(MESSAGE_PAGE * 2 + 20);
  expect(third.hasOlder).toBe(false);
  // Nothing older: no more reads.
  const calls = provider.calls.length;
  await store.loadOlder();
  expect(provider.calls.length).toBe(calls);
});

test("a live change re-reads the list and merges the new message without dropping older pages", async () => {
  const provider = new MockImessageProvider("ready", NOON, { long: true });
  const store = new ImessageStore(provider);
  await store.start();
  await store.select(30);
  await store.loadOlder();
  const before = store.getSnapshot().conversation!.messages.length;
  provider.receive(30, "just now", "+1 (555) 010-7788", NOON + 60_000);
  await settle();
  const after = store.getSnapshot();
  expect(after.conversation!.messages.length).toBe(before + 1);
  expect(after.conversation!.messages.at(-1)?.text).toBe("just now");
  expect(after.threads[0]?.chat_id).toBe(30);
  expect(after.selected).toBe(30);
});

test("a change in another thread re-reads the list but not the open conversation", async () => {
  const provider = new MockImessageProvider("ready", NOON);
  const store = new ImessageStore(provider);
  await store.start();
  await settle();
  const reads = () => provider.calls.filter((call) => call.op === ImessageOps.messages).length;
  const opened = reads();
  provider.receive(4, "lease signed", "+1 (555) 010-4411", NOON + 60_000);
  await settle();
  expect(reads()).toBe(opened);
  expect(store.getSnapshot().threads[0]?.chat_id).toBe(4);
  expect(store.getSnapshot().selected).toBe(7);
});

test("the setting turned on while the page is open reads everything", async () => {
  const provider = new MockImessageProvider("off", NOON);
  const store = new ImessageStore(provider);
  await store.start();
  expect(store.getSnapshot().phase).toBe("off");
  provider.setKind("ready");
  await settle();
  expect(store.getSnapshot().phase).toBe("ready");
  expect(store.getSnapshot().threads.length).toBe(4);
});

test("a list refusal after a ready status switches to that state", async () => {
  const client: PageClient = {
    async call<R>(op: string): Promise<R> {
      if (op === ImessageOps.status) return { enabled: true, access: "ok" } as R;
      throw pageError("cmux.imessage_not_permitted", "denied");
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  };
  const store = new ImessageStore(client);
  await store.start();
  expect(store.getSnapshot().phase).toBe("not_permitted");
});

test("the wire's decimal strings become numbers", () => {
  const normalized = normalizeMessage({
    ...message(1),
    rowid: "42" as unknown as number,
    date_ms: "1791916418192" as unknown as number,
  });
  expect(normalized.rowid).toBe(42);
  expect(normalized.date_ms).toBe(1791916418192);
});

test("merging keeps one copy per rowid, oldest first", () => {
  const merged = mergeMessages([message(3), message(4)], [message(4, { text: "fresh" }), message(5), message(1)]);
  expect(merged.map((m) => m.rowid)).toEqual([1, 3, 4, 5]);
  expect(merged[2]!.text).toBe("fresh");
});

test("rows: a day line per day and after an hour of quiet; sender handles once per group run", () => {
  const day = 86_400_000;
  const messages = [
    message(1, { date_ms: NOON - day, sender: "a" }),
    message(2, { date_ms: NOON - day + 60_000, sender: "a" }),
    message(3, { date_ms: NOON - day + 120_000, sender: "b" }),
    message(4, { date_ms: NOON, is_from_me: true, sender: null }),
    message(5, { date_ms: NOON + 60_000, is_from_me: true, sender: null }),
    message(6, { date_ms: NOON + 2 * 3_600_000, sender: "a" }),
  ];
  const rows = conversationRows(messages, true, 0);
  expect(rows.map((row) => (row.kind === "day" ? "day" : row.message.rowid))).toEqual([
    "day",
    1,
    2,
    3,
    "day",
    4,
    5,
    "day",
    6,
  ]);
  const byRow = new Map(rows.flatMap((row) => (row.kind === "message" ? [[row.message.rowid, row] as const] : [])));
  expect(byRow.get(1)).toMatchObject({ sender: "a", first: true, last: false });
  expect(byRow.get(2)).toMatchObject({ sender: undefined, first: false, last: true });
  expect(byRow.get(3)).toMatchObject({ sender: "b", first: true, last: true });
  expect(byRow.get(4)).toMatchObject({ sender: undefined, first: true, last: false });
  expect(byRow.get(5)).toMatchObject({ first: false, last: true });
  // A 1:1 thread never names the sender.
  expect(conversationRows(messages, false, 0).some((row) => row.kind === "message" && row.sender)).toBe(false);
});

test("list times read as Messages does: a time today, Yesterday, a weekday, then a date", () => {
  const day = 86_400_000;
  expect(relativeKind(NOON - 3_600_000, NOON, 0).kind).toBe("time");
  expect(relativeKind(NOON - day, NOON, 0).kind).toBe("yesterday");
  expect(relativeKind(NOON - 3 * day, NOON, 0).kind).toBe("weekday");
  expect(relativeKind(NOON - 9 * day, NOON, 0).kind).toBe("date");
  // 23:30 UTC the day before is today east of UTC+1.
  expect(relativeKind(NOON - 12.5 * 3_600_000, NOON, 120).kind).toBe("time");
});

test("avatars and chips: initials for names only, attachment names without their folder", () => {
  expect(initials("Weekend hike")).toBe("WH");
  expect(initials("+1 (555) 010-2233")).toBe("");
  expect(initials("sam.rivera@example.com")).toBe("");
  expect(attachmentName({ name: "~/Library/Messages/Attachments/ab/12/IMG_0001.heic", mime_type: "image/heic" })).toBe(
    "IMG_0001.heic",
  );
  expect(attachmentName({ name: null, mime_type: "image/png" })).toBeUndefined();
});
