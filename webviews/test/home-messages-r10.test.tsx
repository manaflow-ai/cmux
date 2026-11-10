// Review round 10 of cmux#37736 (Codex BLOCK at e973eac1): a sent file's kept bytes pass to the
// outbox and stay until that send settles (F2), a send the owner refused for a file it let go of
// goes again under a new key (F3, as HomeStore `uploadAgainAfterSweep`), and the trays upload with
// the latest store's service after a reconnect (F5).
import { expect, test } from "bun:test";

const { AttachmentDrafts } = await import("../src/pages/home-messages/transcript/attachmentDrafts");
const { KeptPendingCarry } = await import("../src/pages/home-messages/outbox");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { pageError } = await import("../src/pages/shared/pageClient");
type HomeAttachment = import("../src/pages/home-channels/types").HomeAttachment;
type KeptAttachments = import("../src/pages/home-messages/transcript/attachmentDrafts").KeptAttachments;
type PendingSend = import("../src/pages/home-channels/store").PendingSend;

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

function part(hash: string, byteCount = 5, name = "notes.txt"): HomeAttachment {
  return { type: "attachment", hash, name, mimeType: "text/plain", byteCount };
}

/** The app's books: tray entries (whose remove lets their bytes go unless the outbox names them,
 * HomeMessagesAttachmentDrafts.releaseBytes) and the outbox's rows. */
function books() {
  const entries = new Map<string, HomeAttachment>();
  const bytes = new Map<string, Blob>();
  const outbox = new Map<string, PendingSend>();
  const calls: string[] = [];
  const named = (hash: string) =>
    entries.has(hash) || [...outbox.values()].some((row) => row.attachments?.some((kept) => kept.hash === hash));
  const keeper = {
    load: async (): Promise<KeptAttachments> => ({ attachments: {}, legacy: {} }),
    put: (_conversation: string, kept: HomeAttachment) => void entries.set(kept.hash, kept),
    remove: (_conversation: string, hash: string) => {
      calls.push(`attachments.remove ${hash}`);
      entries.delete(hash);
      if (!named(hash)) bytes.delete(hash);
    },
    release: () => {},
    write: async (hash: string, file: Blob) => {
      bytes.set(hash, file);
      return true;
    },
    read: async (kept: HomeAttachment) => {
      const blob = bytes.get(kept.hash);
      return blob ? new File([blob], kept.name, { type: kept.mimeType }) : undefined;
    },
  };
  const outboxKeeper = {
    load: async () => [...outbox.values()],
    put: async (send: PendingSend) => {
      calls.push(`outbox.put ${send.key}`);
      outbox.set(send.key, send);
      return true;
    },
    remove: (_conversation: string, key: string) => {
      const row = outbox.get(key);
      outbox.delete(key);
      for (const kept of row?.attachments ?? []) if (!named(kept.hash)) bytes.delete(kept.hash);
    },
  };
  return { keeper, outboxKeeper, entries, bytes, outbox, calls };
}

test("round 10 F2: a sent file's kept bytes stay until the outbox keeps the send, and a relaunched Retry finds them", async () => {
  const app = books();
  const drafts = new AttachmentDrafts(app.keeper);
  await drafts.load();
  drafts.add("a", new File(["notes"], "notes.txt"), async () => part("h1"), "failed");
  await settle();
  await settle();
  expect(await app.bytes.get("h1")?.text()).toBe("notes");

  // The send takes the file: its entry (and so its bytes) stays until the outbox has the send.
  const [ready] = drafts.files("a").map((item) => item.part!);
  drafts.take("a", [ready!]);
  await settle();
  expect(app.entries.has("h1")).toBe(true);
  expect(app.bytes.has("h1")).toBe(true);

  const carry = new KeptPendingCarry(app.outboxKeeper, (hashes) => drafts.handedOver(hashes));
  await carry.load();
  carry.entries = [{ key: "k1", conversation: "a", text: "", createdAt: 1, failed: true, attachments: [ready!] }];
  await settle();
  // The outbox kept it first, then the tray let go of its entry; the bytes are the outbox's now.
  expect(app.calls).toEqual(["outbox.put k1", "attachments.remove h1"]);
  expect(app.entries.has("h1")).toBe(false);
  expect(app.bytes.has("h1")).toBe(true);

  // A relaunch: nothing of the file is in memory, and Retry's upload again reads the app's bytes.
  const relaunched = new AttachmentDrafts(app.keeper);
  await relaunched.load();
  const uploaded: string[] = [];
  relaunched.uploadLegacy(async (_conversation, file) => {
    uploaded.push(await file.text());
    return part("h1");
  }, "failed");
  const parts = await relaunched.resend("a", [ready!], new AbortController().signal);
  expect(parts?.map((kept) => kept.hash)).toEqual(["h1"]);
  expect(uploaded).toEqual(["notes"]);

  // Delivered (or discarded): the outbox lets the bytes go.
  carry.entries = [];
  await settle();
  expect(app.bytes.has("h1")).toBe(false);
});

test("round 10 F2: a send refused before it was logged gives its files back, still kept", async () => {
  const app = books();
  const drafts = new AttachmentDrafts(app.keeper);
  await drafts.load();
  drafts.add("a", new File(["notes"], "notes.txt"), async () => part("h1"), "failed");
  await settle();
  await settle();
  const taken = drafts.take(
    "a",
    drafts.files("a").map((item) => item.part!),
  );
  drafts.giveBack("a", taken);
  drafts.handedOver(["h1"]);
  await settle();
  expect(app.entries.has("h1")).toBe(true);
  expect(drafts.files("a").map((item) => item.part?.hash)).toEqual(["h1"]);
});

/** A cloud owner: a send it refused stays refused under its key (its ledger answers a repeat
 * before it looks at the attachments again); the first send of files is refused `unknown_attachment`. */
function cloudClient(log: { keys: string[] }) {
  const people = [{ id: "me", kind: "human", name: "Me", chief: false }];
  const dm = {
    id: "dm",
    owner: "cloud",
    title: "dm",
    kind: "direct",
    participants: people,
    lastSeq: 0,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
  const rejected = new Set<string>();
  let refused = 0;
  return {
    call: async (op: string, params: Record<string, unknown>) => {
      if (op === HomeOps.send) {
        const key = params.idempotencyKey as string;
        log.keys.push(key);
        if (rejected.has(key)) throw pageError("cmux.page.invalid_params", "unknown_attachment");
        if ((params.attachments as unknown[] | undefined)?.length && refused < 1) {
          refused += 1;
          rejected.add(key);
          throw pageError("cmux.page.invalid_params", "unknown_attachment");
        }
        return { rev: 2 };
      }
      if (op === HomeOps.inbox) return { me: people[0], conversations: [dm], rev: 1 };
      if (op === HomeOps.page) return { conversation: dm, messages: [], hasOlder: false };
      if (op === HomeOps.attachmentSupport) return { local: true, cloud: true };
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

test("round 10 F3: a send refused unknown_attachment goes again under a new key, in its place", async () => {
  const log = { keys: [] as string[] };
  const store = new HomeChannelsStore(cloudClient(log) as never);
  await store.reloadInbox();
  await store.select("dm");
  store.reupload = async (_conversation, parts) => parts.map((kept) => ({ ...kept }));
  expect(await store.send("", undefined, undefined, [part("h1")])).toBe(true);
  await settle();
  await settle();
  expect(log.keys).toHaveLength(2);
  expect(log.keys[1]).not.toBe(log.keys[0]);
  expect(store.getSnapshot().pending.filter((entry) => entry.failed)).toHaveLength(0);
  expect(store.getSnapshot().pending.map((entry) => entry.key)).toEqual([log.keys[1]!]);
});

test("round 10 F3: an uncertain outcome keeps its key for Retry", async () => {
  const keys: string[] = [];
  let fail = true;
  const people = [{ id: "me", kind: "human", name: "Me", chief: false }];
  const client = {
    call: async (op: string, params: Record<string, unknown>) => {
      if (op === HomeOps.send) {
        keys.push(params.idempotencyKey as string);
        if (fail) throw pageError("cmux.owner.unreachable", "no answer");
        return {};
      }
      if (op === HomeOps.inbox)
        return {
          me: people[0],
          conversations: [{ id: "dm", owner: "cloud", title: "dm", kind: "direct", participants: people }],
          rev: 1,
        };
      if (op === HomeOps.page) return { messages: [], hasOlder: false };
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new HomeChannelsStore(client as never);
  store.reupload = async (_conversation, parts) => parts.map((kept) => ({ ...kept }));
  await store.reloadInbox();
  await store.select("dm");
  await store.send("", undefined, undefined, [part("h1")]);
  await settle();
  fail = false;
  store.retry(keys[0]!);
  await settle();
  expect(keys).toEqual([keys[0]!, keys[0]!]);
});

test("round 10 F5: after a reconnect the files upload with the new store's service", async () => {
  const drafts = new AttachmentDrafts();
  const used: string[] = [];
  drafts.uploadLegacy(async () => {
    used.push("first");
    return part("h1");
  }, "failed");
  // DaemonGate remounts on a reconnect: a new store, a new connection, a new uploader.
  drafts.uploadLegacy(async () => {
    used.push("second");
    return part("h1");
  }, "failed");
  drafts.add("a", new File(["notes"], "notes.txt"), async () => part("h1"), "failed");
  await settle();
  const ready = drafts.files("a").map((item) => item.part!);
  drafts.take("a", ready);
  await drafts.resend("a", ready, new AbortController().signal);
  expect(used).toEqual(["second"]);
});

test("round 10 F1: the app's files reach the shown conversation's composer as a drop, and come back out", async () => {
  const { servePageCommands, MessagesPageOps } = await import("../src/pages/home-messages/pageCommands");
  const { MessagesNav } = await import("../src/pages/home-messages/nav");
  const handlers = new Map<string, (params: unknown) => unknown>();
  const reads: Record<string, unknown>[] = [];
  const host = {
    handle: (op: string, run: (params: unknown) => unknown) => {
      handlers.set(op, run);
      return () => handlers.delete(op);
    },
    call: async (op: string, params: Record<string, unknown>) => {
      reads.push({ op, ...params });
      return { data: btoa("quote") };
    },
  };
  const nav = new MessagesNav();
  const store = { getSnapshot: () => ({ selected: "dm", highlight: undefined }) };
  servePageCommands(host as never, () => ({ store: store as never, nav, model: {} as never }));
  const attach = handlers.get(MessagesPageOps.attach)!;
  const files = [{ token: "t1", name: "quote.md", mimeType: "text/markdown", byteCount: 5 }];

  // Nothing takes files (New Message, or no conversation): the app hears false and refuses.
  expect(await attach({ files, request: "r1" })).toEqual({ attached: false });

  const taken: File[] = [];
  const removed: string[] = [];
  nav.setFileDrop(() => ({
    over: () => true,
    leave: () => {},
    drop: () => {},
    take: (list) => {
      taken.push(...list);
      return ["f1"];
    },
    remove: (ids) => void removed.push(...ids),
  }));
  expect(await attach({ files, request: "r2" })).toEqual({ attached: ["f1"] });
  expect(reads).toEqual([{ op: "cmux.home.messages.attachments.intake.read", token: "t1", offset: 0, length: 5 }]);
  expect(taken.map((file) => [file.name, file.type, file.size])).toEqual([["quote.md", "text/markdown", 5]]);
  expect(await taken[0]!.text()).toBe("quote");
  expect(await handlers.get(MessagesPageOps.detach)!({ ids: ["f1"] })).toEqual({ removed: true });
  expect(removed).toEqual(["f1"]);
});
