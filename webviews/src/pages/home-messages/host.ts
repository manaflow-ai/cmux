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
//   the same way, one file per entry (attachmentDrafts.ts `AttachmentKeeper`).
// In a browser (no host) there are no host items and no lights.
import type { PageClient } from "../shared/pageClient";
import type { HomeAttachment } from "../home-channels/types";
import type { DraftKeeper } from "./nav";
import type { AttachmentKeeper, KeptAttachments, LegacyAttachment } from "./transcript/attachmentDrafts";
import type { HiddenConversations, HostMenuItem, MessagesChrome, MessagesHost } from "./types";

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
} as const;

/** The staged files kept by the app across launches. */
export function pageAttachmentKeeper(client: PageClient): AttachmentKeeper {
  return {
    async load() {
      const answer = await client.call<unknown>(MessagesOps.loadAttachments, {}).catch(() => undefined);
      return parseKeptAttachments(answer);
    },
    // A refusal keeps nothing; the page's own trays still hold the files.
    put(conversation, part, at) {
      void client.call(MessagesOps.putAttachment, { conversation, part, at }).catch(() => undefined);
    },
    remove(conversation, hash) {
      void client.call(MessagesOps.removeAttachment, { conversation, hash }).catch(() => undefined);
    },
    release(conversation, migrated) {
      void client.call(MessagesOps.releaseAttachments, { conversation, migrated }).catch(() => undefined);
    },
  };
}

/** The kept files the host sent; anything malformed reads as none. */
export function parseKeptAttachments(value: unknown): KeptAttachments {
  const answer = (value ?? {}) as { attachments?: unknown; legacy?: unknown };
  return {
    attachments: byConversation(answer.attachments, isAttachmentPart),
    legacy: byConversation(answer.legacy, isLegacyAttachment),
  };
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
      // An older host without the op keeps nothing; the page's own copy still holds it.
      void client.call(MessagesOps.saveDraft, { conversation, text }).catch(() => undefined);
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
