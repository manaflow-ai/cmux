// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo 2026-11-22: "there's prob additional lifecycle stuff with making sure they dont get lost
// sometimes if random state happens". A chat's unsent chips live with its session in acpmux
// (`_acpmux/draft_get {attachments: true}`, `_acpmux/draft_set {attachments}`), beside the draft text
// whose inline tokens mark each chip's place; the host's store is only where an older daemon keeps
// them, and where they move from once. Each transition below reads every chip back in its order
// with its contents, its token where it was in the draft.
import { beforeEach, expect, test } from "bun:test";
import { inlineToken, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import {
  draftAttachmentsStore,
  type DraftAttachmentActions,
} from "../src/agent-session/acpmux/composer/draftAttachmentsStore";
import type { KeptAttachments } from "../src/agent-session/acpmux/composer/keptAttachments";

type Session = { draft?: string; chips: ComposerAttachment[] };

/// acpmux as the contract says: each session's draft text and chips in its session folder (`disk`,
/// which a restart reads back), a chip's contents once (a chip named without them keeps the ones
/// held for its id), `[]` forgets. `older`: a daemon from before the chips, which answers no
/// `attachments` and refuses a write without text.
class Daemon {
  disk: Record<string, Session> = {};
  older = false;
  failRead = false;
  requests: { method: string; params: Record<string, unknown> }[] = [];
  restart() {
    this.disk = JSON.parse(JSON.stringify(this.disk));
  }
  async request(method: string, params: Record<string, unknown>): Promise<unknown> {
    this.requests.push({ method, params });
    const sessionId = String(params.sessionId);
    const session = (this.disk[sessionId] ??= { chips: [] });
    if (method === "_acpmux/draft_get") {
      if (this.failRead) throw new Error("acpmux storage unavailable");
      const answer: Record<string, unknown> = { sessionId, draft: session.draft ?? null };
      if (params.attachments === true && !this.older) answer.attachments = session.chips.map((chip) => ({ ...chip }));
      return answer;
    }
    if (method === "_acpmux/draft_set") {
      const answer: Record<string, unknown> = { sessionId };
      if (typeof params.text === "string") {
        session.draft = params.text;
        answer.draft = params.text;
      } else if (this.older || !Array.isArray(params.attachments)) throw new Error("text is required");
      if (Array.isArray(params.attachments)) {
        const had = session.chips;
        session.chips = (params.attachments as ComposerAttachment[]).map((chip) => {
          if (chip.data !== undefined || chip.text !== undefined) return { ...chip };
          const old = had.find((each) => each.id === chip.id);
          return {
            ...chip,
            ...(old?.data ? { data: old.data } : {}),
            ...(old?.text ? { text: old.text } : {}),
          };
        });
        answer.held = session.chips.filter((chip) => chip.data || chip.text).map((chip) => chip.id);
      }
      return answer;
    }
    throw new Error(`unknown ${method}`);
  }
}

/// One connection's actions as App.tsx installs them from direct.ts (readDraftAttachments,
/// writeDraftAttachments).
const connect = (daemon: Daemon): DraftAttachmentActions => ({
  read: (sessionId) => daemon.request("_acpmux/draft_get", { sessionId, attachments: true }),
  write: (sessionId, attachments) => daemon.request("_acpmux/draft_set", { sessionId, attachments }),
});

/// The host's store (AgentPaneDraftAttachments.swift): contents once per chip, nothing for `[]`.
class Host implements KeptAttachments {
  chats = new Map<string, ComposerAttachment[]>();
  failRead = false;
  async read(sessionId: string) {
    if (this.failRead) throw new Error("host link dropped");
    return (this.chats.get(sessionId) ?? []).map((chip) => ({ ...chip }));
  }
  async write(sessionId: string, attachments: ComposerAttachment[]) {
    const had = this.chats.get(sessionId) ?? [];
    const kept = attachments.map((chip) =>
      chip.data !== undefined ? chip : { ...chip, data: had.find((old) => old.id === chip.id)?.data },
    );
    if (kept.length) this.chats.set(sessionId, kept);
    else this.chats.delete(sessionId);
    return { held: kept.filter((chip) => chip.data).map((chip) => chip.id) };
  }
}

/// The page's action map (window.cmuxAcpmuxActions) and its change listeners (notifyDraftActionsChanged).
function page(daemon: Daemon | undefined) {
  let actions: DraftAttachmentActions = daemon ? connect(daemon) : {};
  const listeners = new Set<() => void>();
  return {
    actions: () => actions,
    install(next: DraftAttachmentActions) {
      actions = next;
      for (const listener of listeners) listener();
    },
    actionsChanged: (listener: () => void) => {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
  };
}

const openStore = (map: ReturnType<typeof page>, host: KeptAttachments, connectWaitMs = 2_000) =>
  draftAttachmentsStore(map.actions, host, { actionsChanged: map.actionsChanged, connectWaitMs });

beforeEach(() => {
  try {
    const storage = globalThis.localStorage;
    if (!storage) return;
    for (let index = storage.length - 1; index >= 0; index -= 1) {
      const key = storage.key(index);
      if (key?.startsWith("cmux.draft-attachments.authority.")) storage.removeItem(key);
    }
  } catch {
    // The browser may not expose web storage in a test worker.
  }
});

const shot = (index: number): ComposerAttachment => ({
  id: `shot-${index}`,
  kind: "image",
  inline: true,
  name: `Screenshot ${index}.png`,
  mimeType: "image/png",
  size: 1_000,
  data: btoa(`png-bytes-${index}`),
});
const pasted: ComposerAttachment = {
  id: "paste-1",
  kind: "pasted",
  inline: true,
  name: "Pasted text",
  mimeType: "text/plain",
  size: 4_000,
  text: "a long paste ".repeat(300),
};
const chips = [shot(1), pasted, shot(2)];
const draft = `look ${inlineToken("shot-1")} then ${inlineToken("paste-1")} and ${inlineToken("shot-2")} end`;
const places = (text: string) => chips.map((chip) => text.indexOf(inlineToken(chip.id)));

/// Every chip back, in order, with its contents, and each token where it was in the draft.
async function expectInPlace(daemon: Daemon, sessionId: string, read: ComposerAttachment[]) {
  expect(read.map((chip) => chip.id)).toEqual(chips.map((chip) => chip.id));
  expect(read.map((chip) => chip.data ?? chip.text)).toEqual(chips.map((chip) => chip.data ?? chip.text));
  const text = ((await daemon.request("_acpmux/draft_get", { sessionId })) as { draft: string }).draft;
  expect(places(text)).toEqual(places(draft));
  expect(places(text).every((at) => at > 0)).toBe(true);
}

async function seed(daemon: Daemon, store: KeptAttachments, sessionId: string) {
  await daemon.request("_acpmux/draft_set", { sessionId, text: draft });
  await store.write(sessionId, chips);
}

test("(a) restart: a new page, after the daemon restarts, reads every chip back in its place", async () => {
  const daemon = new Daemon();
  const host = new Host();
  await seed(daemon, openStore(page(daemon), host), "chat-a");
  // The chips are acpmux's, not the host's: a move to another machine carries the session folder.
  expect(host.chats.size).toBe(0);
  daemon.restart();
  const reopened = openStore(page(daemon), new Host());
  await expectInPlace(daemon, "chat-a", await reopened.read("chat-a"));
});

test("(a) a later write names a chip without its contents; acpmux keeps them", async () => {
  const daemon = new Daemon();
  const store = openStore(page(daemon), new Host());
  const answer = await store.write("chat-a", chips);
  expect(answer?.held).toEqual(chips.map((chip) => chip.id));
  // As useKeptAttachments sends a chip acpmux holds: named without its bytes.
  await store.write(
    "chat-a",
    chips.map((chip) => ({ ...chip, data: undefined, text: undefined })),
  );
  await daemon.request("_acpmux/draft_set", { sessionId: "chat-a", text: draft });
  daemon.restart();
  await expectInPlace(daemon, "chat-a", await openStore(page(daemon), new Host()).read("chat-a"));
});

test("(a) a stale host copy never supersedes non-empty acpmux after a reload", async () => {
  const daemon = new Daemon();
  const host = new Host();
  const store = openStore(page(daemon), host);
  await store.write("chat-a", [chips[0]!]);
  // The reloaded adapter has no in-memory hostNewer marker. A non-empty host copy may be stale,
  // so the daemon's non-empty answer remains authoritative.
  host.chats.set("chat-a", [chips[1]!]);
  const reopened = openStore(page(daemon), host);
  expect((await reopened.read("chat-a")).map((chip) => chip.id)).toEqual(["shot-1"]);
  expect(daemon.disk["chat-a"]?.chips.map((chip) => chip.id)).toEqual(["shot-1"]);
  expect(host.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(["paste-1"]);
});

test("(a) a marked host fallback supersedes stale acpmux after a reload", async () => {
  const daemon = new Daemon();
  const host = new Host();
  const store = openStore(page(daemon), host);
  await store.write("chat-a", [chips[0]!]);
  daemon.older = true;
  await store.write("chat-a", [chips[1]!]);
  daemon.older = false;
  const reopened = openStore(page(daemon), host);
  expect((await reopened.read("chat-a")).map((chip) => chip.id)).toEqual(["paste-1"]);
  expect(daemon.disk["chat-a"]?.chips.map((chip) => chip.id)).toEqual(["paste-1"]);
  expect(host.chats.has("chat-a")).toBe(false);
});

test("(a) an intentional empty host fallback survives a reload", async () => {
  const daemon = new Daemon();
  daemon.older = true;
  const host = new Host();
  const store = openStore(page(daemon), host);
  await store.write("chat-a", [chips[0]!]);
  await store.write("chat-a", []);
  daemon.older = false;
  expect(await openStore(page(daemon), host).read("chat-a")).toEqual([]);
  expect(daemon.disk["chat-a"]?.chips).toEqual([]);
});

test("(a) a transient host read does not migrate an empty draft over kept host chips", async () => {
  const daemon = new Daemon();
  const host = new Host();
  host.chats.set("chat-a", [chips[0]!]);
  host.failRead = true;
  const store = openStore(page(daemon), host);
  await expect(store.read("chat-a")).rejects.toThrow("host link dropped");
  expect(daemon.requests.filter((request) => request.method === "_acpmux/draft_set")).toHaveLength(0);
  expect(host.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(["shot-1"]);
});

test("(a) a disconnected daemon authority never becomes an empty replacement", async () => {
  const daemon = new Daemon();
  const host = new Host();
  const map = page(daemon);
  const store = openStore(map, host, 20);
  await store.write("chat-a", [chips[0]!]);
  map.install({});
  await expect(store.read("chat-a")).rejects.toThrow("acpmux is unavailable");
  expect(daemon.disk["chat-a"]?.chips.map((chip) => chip.id)).toEqual(["shot-1"]);
});

test("(a) a disconnected empty host does not claim unknown daemon authority", async () => {
  const store = openStore(page(undefined), new Host(), 20);
  await expect(store.read("chat-a")).rejects.toThrow("draft authority is unknown");
});

test("(a) a daemon read failure is not treated as an older daemon", async () => {
  const daemon = new Daemon();
  const host = new Host();
  host.chats.set("chat-a", [chips[0]!]);
  daemon.failRead = true;
  const store = openStore(page(daemon), host);
  await expect(store.read("chat-a")).rejects.toThrow("acpmux storage unavailable");
  expect(daemon.requests.filter((request) => request.method === "_acpmux/draft_set")).toHaveLength(0);
  expect(host.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(["shot-1"]);
});

test("(b) session switch: A, then B, then A shows A's chips in place and B's own", async () => {
  const daemon = new Daemon();
  const store = openStore(page(daemon), new Host());
  await seed(daemon, store, "chat-a");
  await store.write("chat-b", [shot(9)]);
  expect((await store.read("chat-b")).map((chip) => chip.id)).toEqual(["shot-9"]);
  await expectInPlace(daemon, "chat-a", await store.read("chat-a"));
  expect((await store.read("chat-b")).map((chip) => chip.id)).toEqual(["shot-9"]);
});

test("(c) reconnect: a read while the link is down waits for the new connection's actions", async () => {
  const daemon = new Daemon();
  const map = page(daemon);
  const host = new Host();
  const store = openStore(map, host);
  await seed(daemon, store, "chat-a");
  // The old client is gone (delete window.cmuxAcpmuxActions); the page reads as it mounts.
  map.install({});
  const reading = store.read("chat-a");
  await new Promise((resolve) => setTimeout(resolve, 20));
  // The new client installs its map and calls notifyDraftActionsChanged.
  map.install(connect(daemon));
  await expectInPlace(daemon, "chat-a", await reading);
  // Another client (another pane, the CLI's page) reads the same chips.
  await expectInPlace(daemon, "chat-a", await openStore(page(daemon), new Host()).read("chat-a"));
});

test("(c) a page whose client never connects reads the host's chips after the wait", async () => {
  const host = new Host();
  host.chats.set("chat-a", chips);
  const store = openStore(page(undefined), host, 30);
  expect((await store.read("chat-a")).map((chip) => chip.id)).toEqual(chips.map((chip) => chip.id));
});

test("(d) older daemon: the chips stay with the host, then move to acpmux once it keeps them", async () => {
  const daemon = new Daemon();
  daemon.older = true;
  const host = new Host();
  const store = openStore(page(daemon), host);
  await seed(daemon, store, "chat-a");
  expect(host.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(chips.map((chip) => chip.id));
  await expectInPlace(daemon, "chat-a", await store.read("chat-a"));
  // The daemon updates; the next page finds acpmux holding none and the host's chips.
  daemon.older = false;
  daemon.restart();
  const upgraded = openStore(page(daemon), host);
  await expectInPlace(daemon, "chat-a", await upgraded.read("chat-a"));
  expect(daemon.disk["chat-a"]?.chips.map((chip) => chip.id)).toEqual(chips.map((chip) => chip.id));
  // Moved once: the host forgets them, so a chip removed later never comes back from it.
  expect(host.chats.has("chat-a")).toBe(false);
  await upgraded.write("chat-a", [chips[0]!]);
  expect((await openStore(page(daemon), host).read("chat-a")).map((chip) => chip.id)).toEqual(["shot-1"]);
});

test("(d) a refused acpmux write goes to the host, and the next one carries the contents back", async () => {
  const daemon = new Daemon();
  const host = new Host();
  const map = page(daemon);
  const store = openStore(map, host);
  await seed(daemon, store, "chat-a");
  const flaky = connect(daemon);
  map.install({ ...flaky, write: async () => Promise.reject(new Error("link dropped")) });
  // The hook names chips acpmux held without their contents: the host gets them in full.
  const stripped = chips.map((chip) => ({ ...chip, data: undefined, text: undefined }));
  const answer = await store.write("chat-a", stripped);
  expect(answer?.held).toEqual(chips.filter((chip) => chip.data).map((chip) => chip.id));
  expect(host.chats.get("chat-a")?.map((chip) => chip.data ?? chip.text)).toEqual(
    chips.map((chip) => chip.data ?? chip.text),
  );
  await expectInPlace(daemon, "chat-a", await store.read("chat-a"));
  map.install(connect(daemon));
  await store.write("chat-a", stripped);
  expect(host.chats.has("chat-a")).toBe(false);
  daemon.restart();
  await expectInPlace(daemon, "chat-a", await openStore(page(daemon), new Host()).read("chat-a"));
});

test("(d) a late rejected write cannot replace a later successful write", async () => {
  const daemon = new Daemon();
  const host = new Host();
  const map = page(daemon);
  const store = openStore(map, host);
  let started!: () => void;
  let release!: () => void;
  const firstStarted = new Promise<void>((resolve) => {
    started = resolve;
  });
  const firstGate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const request = daemon.request.bind(daemon);
  let sets = 0;
  daemon.request = async (method, params) => {
    if (method === "_acpmux/draft_set" && sets++ === 0) {
      started();
      await firstGate;
      throw new Error("old daemon");
    }
    return request(method, params);
  };
  const first = store.write("chat-a", [chips[0]!]);
  await firstStarted;
  const second = store.write("chat-a", [chips[1]!]);
  release();
  await Promise.all([first, second]);
  expect(daemon.disk["chat-a"]?.chips.map((chip) => chip.id)).toEqual(["paste-1"]);
  expect(host.chats.has("chat-a")).toBe(false);
});

test("sending forgets the chips in acpmux: `[]` leaves none to come back", async () => {
  const daemon = new Daemon();
  const store = openStore(page(daemon), new Host());
  await seed(daemon, store, "chat-a");
  await store.write("chat-a", []);
  daemon.restart();
  expect(await openStore(page(daemon), new Host()).read("chat-a")).toEqual([]);
});
