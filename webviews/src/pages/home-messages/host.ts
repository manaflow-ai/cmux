// The Messages page's host bridge (`cmux.home.messages.*`, HomeMessagesPage.swift): what only the
// app knows or does. The conversations themselves come from the daemon through the Channels data
// layer; the host adds
// - `menu {kind, conversation?}`: a row's catalog items (Group Info, Mute, Rename, Add People, Leave,
//   Chat Colors…, a Chief's Usage, Import Memories, Archive and Delete) or the compose button's
//   (New Message, New Chief, New Channel, Invite, Show Hidden Conversations, the teams), each with
//   the registry's own title;
// - `perform {action, arguments}`: runs one of them through the action registry, as the palette and
//   the CLI do (the person's click only; Delete Conversation… asks first, natively);
// - the `chrome` stream: the window's traffic lights over the page's top-left, so the list's header
//   and the compose button keep clear of them;
// - the `hidden` stream `{hidden: {[conversation]: seq}}`: the conversations deleted from the list
//   (this Mac's per-account list, HomeSidebarSource), each listed again by a message after `seq`;
// - `drafts.load {}` -> `{drafts: {[conversation]: text}}` and `drafts.save {conversation, text}`:
//   the composer drafts, kept in HomeStore's draft cache across launches (nav.ts `DraftKeeper`);
// - `attachments.load {}` -> `{attachments: {[conversation]: [part]}, legacy: {[conversation]:
//   [{hash, name, mimeType, data}]}}`, `attachments.put {conversation, part, at}`, `attachments.remove
//   {conversation, hash}` and `attachments.release {conversation, migrated}`: the staged files, kept
//   the same way, one file per entry (attachmentDrafts.ts `AttachmentKeeper`); `files: {[conversation]:
//   {[hash]: at}}` names the ones whose bytes the app keeps, written with `attachments.write {hash,
//   offset, byteCount, data}` and read with `attachments.read {hash, offset, length}` (~1 MB frames).
// - the `list` stream (HomeMessagesListFeed.swift): each row's Chief tag, the Cloud note, the
//   teammates with no DM yet, the header's sizes at the sidebar's density and text size;
// - `width.load {}` -> `{width}` and `width.save {width}`: the list's width kept per window;
// - `dragBand {band, controls}`: the list header's band, whose empty space moves the window.
// In a browser (no host) there are no host items and no lights.
import type { PageClient } from "../shared/pageClient";
import type { HomeAttachment } from "../home-channels/types";
import type { DraftKeeper } from "./nav";
import type { AttachmentKeeper, KeptAttachments, LegacyAttachment } from "./transcript/attachmentDrafts";
import type { Rect } from "./list/layout";
import type {
  HeaderMetrics,
  HiddenConversations,
  HostMenuItem,
  ListFacts,
  ListPerson,
  MessagesChrome,
  MessagesHost,
} from "./types";

export const MessagesOps = {
  menu: "cmux.home.messages.menu",
  perform: "cmux.home.messages.perform",
  chrome: "cmux.home.messages.chrome",
  hidden: "cmux.home.messages.hidden",
  loadDrafts: "cmux.home.messages.drafts.load",
  saveDraft: "cmux.home.messages.drafts.save",
  loadAttachments: "cmux.home.messages.attachments.load",
  putAttachment: "cmux.home.messages.attachments.put",
  removeAttachment: "cmux.home.messages.attachments.remove",
  releaseAttachments: "cmux.home.messages.attachments.release",
  writeAttachment: "cmux.home.messages.attachments.write",
  readAttachment: "cmux.home.messages.attachments.read",
  readOffered: "cmux.home.messages.attachments.intake.read",
  list: "cmux.home.messages.list",
  loadWidth: "cmux.home.messages.width.load",
  saveWidth: "cmux.home.messages.width.save",
  dragBand: "cmux.home.messages.dragBand",
} as const;

/** A kept file's bytes move in frames this size (as the upload's own); reads are a multiple of 3. */
const WRITE_BYTES = 1024 * 1024;
const READ_BYTES = 3 * 1024 * 1024;

/** The staged files kept by the app across launches. */
export function pageAttachmentKeeper(client: PageClient): AttachmentKeeper {
  return {
    async load() {
      const answer = await client.call<unknown>(MessagesOps.loadAttachments, {}).catch(() => undefined);
      return parseKeptAttachments(answer);
    },
    // Each answers once the app holds the change (false: it refused, and the page's own trays still
    // hold the files), so the trays let nothing go, and hold a reload, until then.
    put(conversation, part, at) {
      return answered(client.call(MessagesOps.putAttachment, { conversation, part, at }));
    },
    remove(conversation, hash) {
      return answered(client.call(MessagesOps.removeAttachment, { conversation, hash }));
    },
    release(conversation, migrated) {
      return answered(client.call(MessagesOps.releaseAttachments, { conversation, migrated }));
    },
    // One file's bytes, in order; the app refuses past its bound (nothing kept, the part still is).
    async write(hash, file) {
      try {
        for (let offset = 0; offset < file.size; offset += WRITE_BYTES) {
          const bytes = new Uint8Array(await file.slice(offset, offset + WRITE_BYTES).arrayBuffer());
          await client.call(MessagesOps.writeAttachment, { hash, offset, byteCount: file.size, data: toBase64(bytes) });
        }
        return true;
      } catch {
        return false;
      }
    },
    async read(part) {
      try {
        const pieces: Uint8Array[] = [];
        for (let offset = 0; offset < part.byteCount; offset += READ_BYTES) {
          const piece = await client.call<{ data?: string }>(MessagesOps.readAttachment, {
            hash: part.hash,
            offset,
            length: Math.min(READ_BYTES, part.byteCount - offset),
          });
          pieces.push(fromBase64(piece.data ?? ""));
        }
        const file = new File(pieces as BlobPart[], part.name, { type: part.mimeType });
        return file.size === part.byteCount ? file : undefined;
      } catch {
        return undefined;
      }
    },
  };
}

/** A keeper call's answer: true once the app holds the change, false when it refused or the call
 * failed (never a rejection, so a caller waits on it without a catch). */
export function answered(call: Promise<unknown>): Promise<boolean> {
  return call.then(
    () => true,
    () => false,
  );
}

/** An offered file's bytes, read from the app in frames (pageCommands.ts `attach`). */
export async function readOffered(
  client: Pick<PageClient, "call">,
  offer: { token: string; name: string; mimeType: string; byteCount: number },
): Promise<File | undefined> {
  try {
    const pieces: Uint8Array[] = [];
    for (let offset = 0; offset < offer.byteCount; offset += READ_BYTES) {
      const piece = await client.call<{ data?: string }>(MessagesOps.readOffered, {
        token: offer.token,
        offset,
        length: Math.min(READ_BYTES, offer.byteCount - offset),
      });
      pieces.push(fromBase64(piece.data ?? ""));
    }
    const file = new File(pieces as BlobPart[], offer.name, offer.mimeType ? { type: offer.mimeType } : {});
    return file.size === offer.byteCount ? file : undefined;
  } catch {
    return undefined;
  }
}

function toBase64(bytes: Uint8Array): string {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
}

function fromBase64(data: string): Uint8Array {
  const text = atob(data);
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes;
}

/** The kept files the host sent; anything malformed reads as none. */
export function parseKeptAttachments(value: unknown): KeptAttachments {
  const answer = (value ?? {}) as { attachments?: unknown; legacy?: unknown; files?: unknown };
  const out: KeptAttachments = {
    attachments: byConversation(answer.attachments, isAttachmentPart),
    legacy: byConversation(answer.legacy, isLegacyAttachment),
  };
  const files = keptFiles(answer.files);
  if (Object.keys(files).length) out.files = files;
  return out;
}

/** `{[conversation]: {[hash]: at}}`; anything else reads as none. */
function keptFiles(value: unknown): Record<string, Record<string, number>> {
  const out: Record<string, Record<string, number>> = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) return out;
  for (const [conversation, times] of Object.entries(value as Record<string, unknown>)) {
    if (!times || typeof times !== "object" || Array.isArray(times)) continue;
    const kept: Record<string, number> = {};
    for (const [hash, at] of Object.entries(times as Record<string, unknown>))
      if (typeof at === "number" && Number.isFinite(at)) kept[hash] = at;
    if (Object.keys(kept).length) out[conversation] = kept;
  }
  return out;
}

function byConversation<T>(value: unknown, valid: (item: unknown) => item is T): Record<string, T[]> {
  const out: Record<string, T[]> = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) return out;
  for (const [conversation, items] of Object.entries(value as Record<string, unknown>)) {
    if (!Array.isArray(items)) continue;
    const kept = items.filter(valid);
    if (kept.length) out[conversation] = kept;
  }
  return out;
}

function isAttachmentPart(item: unknown): item is HomeAttachment {
  const part = item as Partial<HomeAttachment> | null;
  return (
    !!part &&
    typeof part === "object" &&
    part.type === "attachment" &&
    typeof part.hash === "string" &&
    typeof part.name === "string" &&
    typeof part.mimeType === "string" &&
    typeof part.byteCount === "number"
  );
}

function isLegacyAttachment(item: unknown): item is LegacyAttachment {
  const file = item as Partial<LegacyAttachment> | null;
  return (
    !!file &&
    typeof file === "object" &&
    typeof file.hash === "string" &&
    typeof file.name === "string" &&
    typeof file.mimeType === "string" &&
    typeof file.data === "string"
  );
}

/** The composer drafts kept by the app across launches. */
export function pageDraftKeeper(client: PageClient): DraftKeeper {
  return {
    async load() {
      const answer = await client.call<{ drafts?: unknown }>(MessagesOps.loadDrafts, {}).catch(() => undefined);
      return parseDrafts(answer?.drafts);
    },
    save(conversation, text) {
      // An older host without the op keeps nothing; the page's own copy still holds it. The answer
      // says when the app holds it (nav.ts holds a reload until then).
      return answered(client.call(MessagesOps.saveDraft, { conversation, text }));
    },
  };
}

/** The drafts the host sent: text values by conversation; anything else reads as none. */
export function parseDrafts(value: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) return out;
  for (const [conversation, text] of Object.entries(value as Record<string, unknown>)) {
    if (typeof text === "string" && text) out[conversation] = text;
  }
  return out;
}

/** A conversation of a Chief archived on this Mac: hidden until it is unarchived (no message lists it). */
export const ARCHIVED_SEQ = Number.MAX_SAFE_INTEGER;

/** The hidden set the host sent: whole seqs by conversation, and the archived Chiefs' conversations
 * (`archived`, hidden whatever comes); anything else reads as none. */
export function parseHidden(value: unknown): HiddenConversations {
  const hidden = (value as { hidden?: unknown } | null | undefined)?.hidden;
  const archived = (value as { archived?: unknown } | null | undefined)?.archived;
  const out = new Map<string, number>();
  if (Array.isArray(archived)) for (const id of archived) if (typeof id === "string" && id) out.set(id, ARCHIVED_SEQ);
  if (!hidden || typeof hidden !== "object" || Array.isArray(hidden)) return out;
  for (const [conversation, seq] of Object.entries(hidden as Record<string, unknown>)) {
    if (typeof seq === "number" && Number.isFinite(seq) && seq >= 0)
      out.set(conversation, Math.max(seq, out.get(conversation) ?? 0));
  }
  return out;
}

/** The bridge over the app's page client. */
export function pageMessagesHost(client: PageClient): MessagesHost {
  return {
    async menu(kind, conversation) {
      try {
        const answer = await client.call<{ items?: HostMenuItem[] }>(MessagesOps.menu, {
          kind,
          ...(conversation ? { conversation } : {}),
        });
        return Array.isArray(answer?.items) ? answer.items.filter(isMenuItem) : [];
      } catch {
        // An older host without the op: the list's own items only.
        return [];
      }
    },
    async perform(item) {
      // A refusal (no click behind it, an action the host no longer offers) changes nothing.
      await client.call(MessagesOps.perform, { action: item.action, arguments: item.arguments ?? {} }).catch(() => {});
    },
    subscribeChrome(listener) {
      return follow(client, MessagesOps.chrome, (data) => listener(chromeOf(data as MessagesChrome)));
    },
    subscribeHidden(listener) {
      return follow(client, MessagesOps.hidden, (data) => listener(parseHidden(data)));
    },
    subscribeList(listener) {
      return follow(client, MessagesOps.list, (data) => listener(parseListFacts(data)));
    },
    async loadWidth() {
      const answer = await client.call<{ width?: unknown }>(MessagesOps.loadWidth, {}).catch(() => undefined);
      const width = answer?.width;
      return typeof width === "number" && Number.isFinite(width) && width > 0 ? width : null;
    },
    saveWidth(width) {
      void client
        .call(MessagesOps.saveWidth, { width: width === null ? null : Math.round(width) })
        .catch(() => undefined);
    },
    setDragBand(band, controls) {
      void client.call(MessagesOps.dragBand, { band, controls }).catch(() => undefined);
    },
  };
}

/** No facts: no tags, no note, no teammates, the standard header. */
export const NO_LIST_FACTS: ListFacts = { badges: new Map(), teammates: [], people: [] };

/** The list facts the host sent; anything malformed reads as none. */
export function parseListFacts(value: unknown): ListFacts {
  const data = (value ?? {}) as {
    badges?: unknown;
    note?: unknown;
    teammates?: unknown;
    people?: unknown;
    header?: unknown;
  };
  const badges = new Map<string, string>();
  if (data.badges && typeof data.badges === "object" && !Array.isArray(data.badges))
    for (const [id, tag] of Object.entries(data.badges as Record<string, unknown>))
      if (typeof tag === "string" && tag) badges.set(id, tag);
  const people = (list: unknown): ListPerson[] =>
    Array.isArray(list)
      ? list.filter(
          (p): p is ListPerson =>
            !!p && typeof p === "object" && typeof p.id === "string" && !!p.id && typeof p.name === "string",
        )
      : [];
  const header = data.header as Partial<HeaderMetrics> | undefined;
  const sizes = ["side", "chipHeight", "chipGap", "chipPadding", "textStep"] as const;
  const validHeader =
    !!header &&
    sizes.every((key) => typeof header[key] === "number" && Number.isFinite(header[key]) && header[key] >= 0);
  return {
    badges,
    ...(typeof data.note === "string" && data.note ? { note: data.note } : {}),
    teammates: people(data.teammates),
    people: people(data.people),
    ...(validHeader ? { header: header as HeaderMetrics } : {}),
  };
}

/** Subscribes to a host stream; the returned stop ends it, also before the subscribe answered. */
function follow(client: PageClient, stream: string, listener: (data: unknown) => void): () => void {
  let stop: (() => void) | undefined;
  let ended = false;
  void client
    .subscribe<unknown>(stream, listener)
    .then((unsubscribe) => {
      if (ended) unsubscribe();
      else stop = unsubscribe;
    })
    .catch(() => {});
  return () => {
    ended = true;
    stop?.();
  };
}

/** No host: a browser or the gallery without one. */
export const noMessagesHost: MessagesHost = {
  menu: async () => [],
  perform: async () => {},
  subscribeChrome: () => () => {},
  subscribeHidden: () => () => {},
  subscribeList: () => () => {},
  loadWidth: async () => null,
  saveWidth: () => {},
  setDragBand: (_band: Rect, _controls: readonly Rect[]) => {},
};

function isMenuItem(value: unknown): value is HostMenuItem {
  const item = value as HostMenuItem | null;
  return !!item && typeof item.id === "string" && typeof item.title === "string" && typeof item.action === "string";
}

function chromeOf(data: MessagesChrome | null | undefined): MessagesChrome {
  const lights = data?.windowControls;
  const valid =
    lights &&
    [lights.x, lights.y, lights.width, lights.height].every((n) => typeof n === "number" && Number.isFinite(n));
  const color = data?.unreadColor;
  return {
    windowControls: valid ? lights : null,
    ...(typeof color === "string" && /^#[0-9a-f]{6}$/i.test(color) ? { unreadColor: color } : {}),
  };
}
