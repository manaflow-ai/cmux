// Leo, 2026-10-26: "why the FUCK SHOULD THERE BE A FUCKING SIZE CAP ANYWAYS ... I ALREADY SAID WE NEED
// ARBITARRILY LARGE FILES OF ANY TYPE" (standing order: attachments take arbitrarily large files of
// any type, with no cap). The Channels composer stopped taking files at 10 (`MAX_ATTACHMENTS`), and the
// daemon client refused a send naming more than 10. The owner's real bound is 16 parts per message
// (cmux-conversation `MAX_PARTS`), so a send with more files goes as several messages, in order.
//
// The send runs through the real store and the real daemon client (daemonHome.ts); only the daemon's
// socket is a stand-in, refusing a message over the owner's part limit as its reducer does.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
Object.assign(dom.window, {
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
});
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "File",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = new Map(keys.map((key) => [key, scope[key]]));
Object.assign(scope, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MouseEvent: dom.window.MouseEvent,
  KeyboardEvent: dom.window.KeyboardEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => {
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom.window.close();
});

const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { DaemonHomeClient } = await import("../src/pages/home-channels/daemonHome");
const { Composer } = await import("../src/pages/home-channels/Composer");
const { messageGroups } = await import("../src/pages/home-channels/attachmentService");
const { HomeOps, MESSAGE_PARTS } = await import("../src/pages/home-channels/types");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/home-channels/generated/strings.json")).default;
type HomeAttachment = import("../src/pages/home-channels/types").HomeAttachment;
type DaemonSocket = import("../src/pages/shared/daemonSocket").DaemonSocket;

/** The owner's parts per message (cmux-tui/crates/cmux-conversation/src/lib.rs `MAX_PARTS`). */
const OWNER_MAX_PARTS = 16;

const attachment = (index: number): HomeAttachment => ({
  type: "attachment",
  hash: `h${index}`,
  name: `file-${index}.bin`,
  mimeType: "application/octet-stream",
  byteCount: 5 * 1024 ** 3 + index,
});

test("the page's per-message bound is the owner's, not a cap of its own", () => {
  expect(MESSAGE_PARTS).toBe(OWNER_MAX_PARTS);
});

test("any number of files splits into messages within the owner's part limit, in order", () => {
  for (const count of [0, 1, 15, 16, 17, 64, 65, 1000]) {
    for (const text of ["", "caption"]) {
      const files = Array.from({ length: count }, (_, index) => index);
      const groups = messageGroups(text, files);
      expect(groups.flatMap((group) => group.files)).toEqual(files);
      expect(groups.map((group) => group.text)).toEqual(groups.map((_, index) => (index === 0 ? text : "")));
      for (const group of groups)
        expect(group.files.length + (group.text ? 1 : 0)).toBeLessThanOrEqual(OWNER_MAX_PARTS);
      expect(groups.every((group, index) => index === 0 || group.files.length > 0)).toBe(true);
    }
  }
});

/** The owner's socket; `refuseOnce`: the first message naming that hash is refused (a transient
 * failure), the next is taken. */
function ownerSocket(refuseOnce?: string) {
  const sent: Array<{ key: string; parts: Array<Record<string, unknown>> }> = [];
  let refused = false;
  const socket = {
    async request(cmd: string, params?: Record<string, unknown>): Promise<unknown> {
      if (cmd === "identify") return { capabilities: [] };
      if (cmd !== "conversation-op") return {};
      const op = params?.op as { kind: string; parts: Array<Record<string, unknown>> };
      // The owner's reducer: `parts.is_empty() || parts.len() > MAX_PARTS` is invalid_parts.
      if (op.parts.length === 0 || op.parts.length > OWNER_MAX_PARTS) throw new Error("invalid_parts");
      if (!refused && refuseOnce && op.parts.some((part) => part.hash === refuseOnce)) {
        refused = true;
        throw new Error("unavailable");
      }
      sent.push({ key: String(params?.idempotency_key), parts: op.parts });
      return { rev: sent.length };
    },
    onEvent: () => () => {},
    onClose: () => () => {},
  } as unknown as DaemonSocket;
  return { socket, sent };
}

async function openStore(socket: DaemonSocket) {
  const home = new DaemonHomeClient(socket);
  const me = { id: "me", kind: "human" as const, name: "Me", chief: false };
  const conversation = {
    id: "conv_local",
    owner: "local",
    title: "Files",
    kind: "group",
    participants: [me],
    lastSeq: 0,
    rev: 0,
    updatedAt: 0,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
  const client = {
    async call(op: string, params: Record<string, unknown>) {
      if (op === HomeOps.send) return home.call(op, params);
      if (op === HomeOps.inbox) return { me, conversations: [conversation], rev: 1 };
      if (op === HomeOps.page) return { conversation, messages: [] };
      return {};
    },
    async subscribe() {
      return () => {};
    },
    handle: () => () => {},
  };
  const store = new HomeChannelsStore(client as never);
  const stop = store.subscribe(() => {});
  await store.start();
  expect(store.getSnapshot().selected).toBe("conv_local");
  return { store, stop };
}

const settle = async () => {
  for (let turn = 0; turn < 40; turn++) await new Promise((resolve) => setTimeout(resolve, 0));
};

test("a send with 65 files over 4 GiB each reaches the owner, every file once and in order", async () => {
  const { socket, sent } = ownerSocket();
  const { store, stop } = await openStore(socket);

  const files = Array.from({ length: 65 }, (_, index) => attachment(index));
  expect(await store.send("here they are", undefined, undefined, files)).toBe(true);
  for (let turn = 0; turn < 20 && sent.length < 5; turn++) await new Promise((resolve) => setTimeout(resolve, 0));

  expect(store.getSnapshot().pending.filter((entry) => entry.failed)).toEqual([]);
  expect(sent.map((message) => message.parts.length)).toEqual([16, 16, 16, 16, 2]);
  expect(sent[0]!.parts[0]).toEqual({ type: "text", text: "here they are" });
  const hashes = sent.flatMap((message) =>
    message.parts.filter((part) => part.type === "attachment").map((part) => part.hash),
  );
  expect(hashes).toEqual(files.map((file) => file.hash));
  expect(new Set(sent.map((message) => message.key)).size).toBe(sent.length);
  stop();
});

test("the composer takes 65 files at once and keeps attaching more", async () => {
  const container = dom.window.document.getElementById("root")!;
  const strings = createStrings(table, ["en"]);
  const uploaded: string[] = [];
  const service = {
    async upload(_conversation: string, file: File) {
      uploaded.push(file.name);
      return { type: "attachment", hash: file.name, name: file.name, mimeType: "text/plain", byteCount: file.size };
    },
  };
  const root = createRoot(container);
  await act(async () => {
    root.render(
      <Composer
        strings={strings}
        placeholder="Message"
        label="Message"
        onSend={async () => true}
        attachments={{ service: service as never, conversation: "c1" }}
      />,
    );
  });
  const picker = container.querySelector<HTMLInputElement>("input[type=file]")!;
  const pick = async (names: string[]) => {
    const list = names.map((name) => new dom.window.File(["x"], name, { type: "text/plain" }));
    Object.defineProperty(picker, "files", { configurable: true, value: list });
    await act(async () => {
      picker.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
    });
  };
  await pick(Array.from({ length: 65 }, (_, index) => `a${index}.txt`));
  expect(uploaded).toHaveLength(65);
  const attach = container.querySelector<HTMLButtonElement>(`button[aria-label="${strings.t("attach.add")}"]`);
  expect(attach?.disabled ?? false).toBe(false);
  await pick(["one-more.txt"]);
  expect(uploaded).toHaveLength(66);
  await act(async () => root.unmount());
});

// Review finding: a later message of a send went on after an earlier one failed, so it reached the
// owner first and the retry put the failed one after it.
test("a failed middle message holds the rest until its retry is taken, so the owner keeps the order", async () => {
  const files = Array.from({ length: 40 }, (_, index) => attachment(index));
  const { socket, sent } = ownerSocket(files[20]!.hash);
  const { store, stop } = await openStore(socket);
  expect(await store.send("", undefined, undefined, files)).toBe(true);
  await settle();

  const groups = () => sent.map((message) => message.parts.map((part) => part.hash));
  expect(groups()).toEqual([files.slice(0, 16).map((file) => file.hash)]);
  const failed = store.getSnapshot().pending.filter((entry) => entry.failed);
  expect(failed.map((entry) => entry.attachments?.length)).toEqual([16, 8]);

  // Retrying the held last message retries from the failed one.
  store.retry(failed[1]!.key);
  await settle();
  expect(groups()).toEqual([
    files.slice(0, 16).map((file) => file.hash),
    files.slice(16, 32).map((file) => file.hash),
    files.slice(32, 40).map((file) => file.hash),
  ]);
  expect(store.getSnapshot().pending.filter((entry) => entry.failed)).toEqual([]);
  stop();
});
