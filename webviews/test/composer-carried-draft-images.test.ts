// A chat's unsent composer images are kept in acpmux too, so they move with the chat (RFD 0138,
// "Attachments pending in the composer"): composer/carriedDraftImages.ts. The chat's images live in
// one draft whose id the host keeps with its chips; each image is keyed by its chip id, a write names
// the keys it last saw (`base`), and a sent prompt names the keys it took. The fake hub below keeps
// drafts as acpmux's hub/composers.rs does (`merged`, `take_sent`).
import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import * as page from "../src/agent-session/acpmux/composer/carriedDraftImages";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";
import { keptAttachments } from "../src/agent-session/acpmux/pane/draftHost";

type Carried = typeof page;

const image = (id: string, data?: string): ComposerAttachment =>
  ({
    id,
    kind: "image",
    name: `${id}.png`,
    mimeType: "image/png",
    size: 3,
    ...(data ? { data } : {}),
  }) as ComposerAttachment;
const file = (id: string): ComposerAttachment => ({
  id,
  kind: "document",
  name: `${id}.pdf`,
  mimeType: "application/pdf",
  size: 3,
  data: "eA==",
});

type Call = { method: string; params: Record<string, unknown> };
type Held = { id: string; key?: string; mimeType: string; name?: string };

/// acpmux's composers for one chat, as hub/composers.rs keeps them.
function hub() {
  const calls: Call[] = [];
  const drafts = new Map<string, Held[]>();
  const bytes = new Map<string, string>();
  const unknown = () => new AcpmuxRpcError({ message: "unknown", data: { reason: "composer.image.unknown" } });
  const request = async (method: string, params: Record<string, unknown>): Promise<unknown> => {
    calls.push({ method, params });
    if (method === "_acpmux/composers")
      return {
        composers: [...drafts].map(([surfaceId, images]) => ({ surfaceId, name: "Mac", kind: "app", images })),
      };
    if (method === "_acpmux/attachment") {
      const data = bytes.get(String(params.id));
      return data ? { data, mimeType: "image/png" } : {};
    }
    if (method !== "_acpmux/composer_set") throw new Error(`unexpected ${method}`);
    const surface = (params.surface as { id: string }).id;
    const items = params.images as Record<string, unknown>[];
    const had = drafts.get(surface) ?? [];
    const fresh: Held[] = items.map((item) => {
      const key = typeof item.key === "string" ? item.key : undefined;
      if (typeof item.id === "string") {
        if (!bytes.has(item.id)) throw unknown();
        return { id: item.id, mimeType: "image/png", ...(key ? { key } : {}) };
      }
      const id = `sha-${String(item.data)}`;
      bytes.set(id, String(item.data));
      return { id, mimeType: String(item.mimeType), ...(key ? { key } : {}) };
    });
    const base = params.base as string[] | undefined;
    const freshKeys = new Set(fresh.flatMap((img) => (img.key ? [img.key] : [])));
    const kept = base ? had.filter((img) => !img.key || (!base.includes(img.key) && !freshKeys.has(img.key))) : [];
    const next = [...kept, ...fresh];
    if (next.length) drafts.set(surface, next);
    else drafts.delete(surface);
    return { images: fresh.map(({ id, mimeType }) => ({ id, mimeType })) };
  };
  /// A prompt acpmux took: its draft loses exactly the keys it names.
  const accept = (draft: { id: string; keys: string[] } | undefined) => {
    if (!draft) return;
    const left = (drafts.get(draft.id) ?? []).filter((img) => !img.key || !draft.keys.includes(img.key));
    if (left.length) drafts.set(draft.id, left);
    else drafts.delete(draft.id);
  };
  const keysIn = (id: string) => (drafts.get(id) ?? []).map((img) => img.key ?? `(${img.id})`);
  return { calls, drafts, bytes, request, accept, keysIn };
}

/// The host's kept chips per chat (AgentPaneDraftAttachments.swift): an empty list forgets the draft id.
function host() {
  const chats = new Map<string, { attachments: ComposerAttachment[]; draftId?: string }>();
  return {
    chats,
    get: ({ sessionId, withDraftId }: Record<string, unknown>) => {
      const kept = chats.get(String(sessionId)) ?? { attachments: [] };
      return withDraftId ? kept : kept.attachments;
    },
    set: ({ sessionId, attachments, draftId }: Record<string, unknown>) => {
      const list = attachments as ComposerAttachment[];
      const had = chats.get(String(sessionId));
      if (!list.length) chats.delete(String(sessionId));
      else chats.set(String(sessionId), { attachments: list, draftId: (draftId as string) ?? had?.draftId });
      return { held: list.map((chip) => chip.id) };
    },
  };
}

/// Wires draftHost.ts's store to `daemon` and `native` as paneSnapshot.ts does; answers the acpmux
/// writes it started, so a test can wait for them.
function wire(daemon: ReturnType<typeof hub>, native: ReturnType<typeof host>) {
  const writes: Promise<unknown>[] = [];
  (globalThis as { window?: unknown }).window = {
    cmuxAcpmuxActions: {
      "chat.draftAttachments.get": async (params: Record<string, unknown>) => native.get(params),
      "chat.draftAttachments": async (params: Record<string, unknown>) => native.set(params),
      "chat.draftImages.get": ({ sessionId }: Record<string, unknown>) =>
        page.readCarriedImages(daemon.request, String(sessionId)),
      "chat.draftImages.set": ({ sessionId, draftId, attachments }: Record<string, unknown>) => {
        const write = page.writeCarriedImages(
          daemon.request,
          String(sessionId),
          String(draftId ?? ""),
          attachments as ComposerAttachment[],
        );
        writes.push(write);
        return write;
      },
    },
  };
  return { settled: () => Promise.all(writes) };
}

const hadWindow = "window" in globalThis;
const window0 = (globalThis as { window?: unknown }).window;
afterAll(() => {
  if (hadWindow) (globalThis as { window?: unknown }).window = window0;
  else delete (globalThis as { window?: unknown }).window;
});

beforeEach(() => page.forgetDrafts());

/// A second page of the same chat (another pane or window): its own module state, as a page has.
let panes = 0;
const otherPage = async (): Promise<Carried> =>
  (await import(`../src/agent-session/acpmux/composer/carriedDraftImages.ts?pane=${++panes}`)) as Carried;

/// One page's composer for chat `s1` over `daemon` and the shared host: read on open, write on change.
function pane(carried: Carried, daemon: ReturnType<typeof hub>, native: ReturnType<typeof host>) {
  let chips: ComposerAttachment[] = [];
  return {
    get chips() {
      return chips;
    },
    async open() {
      const kept = native.get({ sessionId: "s1", withDraftId: true }) as {
        attachments: ComposerAttachment[];
        draftId?: string;
      };
      if (kept.attachments.length) {
        carried.noteBytes("s1", kept.attachments);
        carried.adoptDraft("s1", kept.draftId ?? carried.draftIdOf("s1"), kept.attachments);
        chips = kept.attachments;
      } else chips = (await carried.readCarriedImages(daemon.request, "s1")).attachments;
    },
    async set(next: ComposerAttachment[]) {
      chips = next;
      const draftId = carried.draftIdOf("s1");
      native.set({ sessionId: "s1", attachments: next, draftId });
      await carried.writeCarriedImages(daemon.request, "s1", draftId, carried.carriedChips("s1", next));
    },
    send(sent: ComposerAttachment[]) {
      daemon.accept(carried.sentDraft("s1", sent));
    },
  };
}

describe("writing a draft's images", () => {
  test("only image chips go, keyed by chip id, with empty text under the chat's draft id", async () => {
    const daemon = hub();
    await page.writeCarriedImages(daemon.request, "s1", "draft-1", [image("a", "QQ=="), file("f"), image("b", "Qg==")]);
    expect(daemon.calls).toHaveLength(1);
    expect(daemon.calls[0]!.params).toMatchObject({
      sessionId: "s1",
      surface: { id: "draft-1", kind: "app" },
      text: "",
    });
    expect(daemon.calls[0]!.params.images).toEqual([
      { type: "image", mimeType: "image/png", data: "QQ==", key: "a", name: "a.png" },
      { type: "image", mimeType: "image/png", data: "Qg==", key: "b", name: "b.png" },
    ]);
    expect(daemon.calls[0]!.params.base).toEqual([]);
  });

  test("an image acpmux holds goes by id and key the next time, even once the host strips its bytes", async () => {
    const daemon = hub();
    await page.writeCarriedImages(daemon.request, "s1", "d", [image("a", "QQ==")]);
    await page.writeCarriedImages(daemon.request, "s1", "d", [image("a"), image("b", "Qg==")]);
    expect(daemon.calls[1]!.params.images).toEqual([
      { id: "sha-QQ==", key: "a" },
      { type: "image", mimeType: "image/png", data: "Qg==", key: "b", name: "b.png" },
    ]);
    expect(daemon.calls[1]!.params.base).toEqual(["a"]);
  });

  test("acpmux losing a held image sends the bytes again once", async () => {
    const daemon = hub();
    await page.writeCarriedImages(daemon.request, "s1", "d", [image("a", "QQ==")]);
    // A new daemon that holds none of it.
    const lost = hub();
    await page.writeCarriedImages(lost.request, "s1", "d", [image("a")]);
    expect(lost.calls).toHaveLength(2);
    expect(lost.calls[1]!.params.images).toEqual([
      { type: "image", mimeType: "image/png", data: "QQ==", key: "a", name: "a.png" },
    ]);
  });

  test("other refusals reach the caller", async () => {
    const request = async () => {
      throw new AcpmuxRpcError({ message: "moving", data: { reason: "transfer.moving" } });
    };
    await expect(page.writeCarriedImages(request, "s1", "d", [image("a", "QQ==")])).rejects.toBeInstanceOf(
      AcpmuxRpcError,
    );
  });

  test("at most 32 images go, and a chip id acpmux would refuse as a key stays the host's", () => {
    const many = Array.from({ length: 40 }, (_, n) => image(`i${n}`, "QQ=="));
    expect(page.carriedChips("s1", many)).toHaveLength(page.MAX_CARRIED_IMAGES);
    expect(page.carriedChips("s1", [image("x".repeat(129), "QQ=="), image("a\nb", "QQ==")])).toEqual([]);
  });

  test("bytes the host read are used for a chip a later write sends without them", () => {
    page.noteBytes("s1", [image("a", "QQ==")]);
    expect(page.carriedChips("s1", [image("a")])[0]!.data).toBe("QQ==");
    expect(page.carriedChips("s2", [image("a")])).toEqual([]);
  });
});

describe("reopening a chat whose host keeps none of its chips", () => {
  async function leftWithOneImage() {
    const daemon = hub();
    const native = host();
    const { settled } = wire(daemon, native);
    await keptAttachments.read("s1");
    await keptAttachments.write("s1", [image("a", "QQ==")]);
    await settled();
    const draftId = native.chats.get("s1")!.draftId!;
    expect(draftId).toBeTruthy();
    expect(daemon.keysIn(draftId)).toEqual(["a"]);
    // The host lost its copy (another Mac, a moved chat): the page opens empty.
    native.chats.clear();
    page.forgetDrafts();
    return { daemon, native, settled, draftId };
  }

  test("its one draft comes back under its id, and a remove there leaves nothing for the next reopen", async () => {
    const { daemon, native, settled, draftId } = await leftWithOneImage();
    const chips = await keptAttachments.read("s1");
    expect(chips.map((chip) => [chip.id, chip.data])).toEqual([["a", "QQ=="]]);
    await keptAttachments.write("s1", []);
    await settled();
    expect(daemon.calls.at(-1)!.params).toMatchObject({ surface: { id: draftId }, images: [], base: ["a"] });
    expect(daemon.drafts.size).toBe(0);
    expect(native.chats.size).toBe(0);
    page.forgetDrafts();
    expect(await keptAttachments.read("s1")).toEqual([]);
  });

  test("a send there takes the image from its draft, so the next reopen restores nothing", async () => {
    const { daemon, draftId } = await leftWithOneImage();
    const chips = await keptAttachments.read("s1");
    const draft = page.sentDraft("s1", chips);
    expect(draft).toEqual({ id: draftId, keys: ["a"] });
    daemon.accept(draft);
    expect(daemon.drafts.size).toBe(0);
    page.forgetDrafts();
    expect(await keptAttachments.read("s1")).toEqual([]);
  });

  test("a later write keeps the chat's draft id with the host's chips", async () => {
    const { native, settled, draftId } = await leftWithOneImage();
    const chips = await keptAttachments.read("s1");
    await keptAttachments.write("s1", [...chips, image("b", "Qg==")]);
    await settled();
    expect(native.chats.get("s1")!.draftId).toBe(draftId);
  });

  test("two drafts (an older build's, one per page): none comes back, none is written, both stay", async () => {
    const daemon = hub();
    const native = host();
    wire(daemon, native);
    daemon.drafts.set("page-1", [{ id: "sha-QQ==", key: "x", mimeType: "image/png" }]);
    daemon.drafts.set("page-2", [{ id: "sha-Qg==", mimeType: "image/png" }]);
    expect(await keptAttachments.read("s1")).toEqual([]);
    expect(daemon.calls.map((call) => call.method)).toEqual(["_acpmux/composers"]);
    expect(daemon.keysIn("page-1")).toEqual(["x"]);
    expect(daemon.keysIn("page-2")).toEqual(["(sha-Qg==)"]);
    expect(native.chats.size).toBe(0);
  });

  test("an older build's draft (images without keys) comes back, and its first write replaces it", async () => {
    const daemon = hub();
    const native = host();
    const { settled } = wire(daemon, native);
    daemon.bytes.set("sha-QQ==", "QQ==");
    daemon.drafts.set("page-1", [{ id: "sha-QQ==", mimeType: "image/png", name: "old.png" }]);
    const chips = await keptAttachments.read("s1");
    expect(chips.map((chip) => [chip.id, chip.name])).toEqual([["carried-sha-QQ==", "old.png"]]);
    await keptAttachments.write("s1", []);
    await settled();
    const set = daemon.calls.find((call) => call.method === "_acpmux/composer_set")!;
    expect(set.params.surface).toMatchObject({ id: "page-1" });
    expect("base" in set.params).toBe(false);
    expect(daemon.drafts.size).toBe(0);
  });

  test("a host's list from an older app (no draft id) still comes back", async () => {
    const daemon = hub();
    const native = host();
    wire(daemon, native);
    native.chats.set("s1", { attachments: [image("a", "QQ==")] });
    expect((await keptAttachments.read("s1")).map((chip) => chip.id)).toEqual(["a"]);
    expect(daemon.calls).toEqual([]);
  });
});

describe("two panes of one chat", () => {
  async function twoPanes() {
    const daemon = hub();
    const native = host();
    const a = pane(page, daemon, native);
    const b = pane(await otherPage(), daemon, native);
    await a.open();
    await a.set([image("a1", "QQ==")]);
    await b.open();
    expect(b.chips.map((chip) => chip.id)).toEqual(["a1"]);
    const draftId = native.chats.get("s1")!.draftId!;
    return { daemon, native, a, b, draftId };
  }

  test("they share the chat's draft; A's remove takes A's image and B's stays", async () => {
    const { daemon, a, b, draftId } = await twoPanes();
    await b.set([...b.chips, image("b1", "Qg==")]);
    expect(daemon.keysIn(draftId)).toEqual(["a1", "b1"]);
    // A never saw b1: its write names only a1 as removed.
    await a.set([]);
    expect(daemon.keysIn(draftId)).toEqual(["b1"]);
    expect([...daemon.drafts.keys()]).toEqual([draftId]);
  });

  test("equal bytes in each pane are two images; removing one leaves the other", async () => {
    const { daemon, a, b, draftId } = await twoPanes();
    await b.set([...b.chips, image("b1", "QQ==")]);
    expect(daemon.drafts.get(draftId)!.map((img) => [img.key, img.id])).toEqual([
      ["a1", "sha-QQ=="],
      ["b1", "sha-QQ=="],
    ]);
    await a.set([]);
    expect(daemon.keysIn(draftId)).toEqual(["b1"]);
    await b.set([image("b1")]);
    expect(daemon.keysIn(draftId)).toEqual(["b1"]);
  });

  test("a send takes only the keys it sent; the other pane's image of the same bytes stays", async () => {
    const { daemon, a, b, draftId } = await twoPanes();
    await a.set([...a.chips, image("a2", "Qg==")]);
    await b.set([image("a1"), image("b1", "QQ==")]);
    expect(daemon.keysIn(draftId)).toEqual(["a2", "a1", "b1"]);
    a.send([image("a1")]);
    expect(daemon.keysIn(draftId)).toEqual(["a2", "b1"]);
  });
});

describe("reading the chat's draft from acpmux", () => {
  test("a daemon without the method gives none", async () => {
    const request = async () => {
      throw new Error("method not found");
    };
    expect(await page.readCarriedImages(request, "s1")).toEqual({ attachments: [] });
  });

  test("a malformed answer, a phone's draft or an empty one gives none", () => {
    expect(page.carriedDraft(undefined)).toBeUndefined();
    expect(page.carriedDraft({ composers: [{ kind: "app", surfaceId: "d", images: [{ id: 3 }] }] })).toEqual({
      id: "d",
      images: [],
    });
    expect(
      page.carriedDraft({
        composers: [
          { kind: "phone", surfaceId: "p", images: [{ id: "h", mimeType: "image/png" }] },
          { kind: "app", surfaceId: "e", images: [] },
        ],
      }),
    ).toBeUndefined();
  });

  test("an image whose bytes are gone is left out", async () => {
    const daemon = hub();
    daemon.drafts.set("d", [
      { id: "sha-QQ==", key: "a", mimeType: "image/png" },
      { id: "sha-gone", key: "b", mimeType: "image/png" },
    ]);
    daemon.bytes.set("sha-QQ==", "QQ==");
    const read = await page.readCarriedImages(daemon.request, "s1");
    expect(read.draftId).toBe("d");
    expect(read.attachments.map((chip) => chip.id)).toEqual(["a"]);
  });
});
