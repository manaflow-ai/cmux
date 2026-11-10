/// What the person typed in a new chat's composer after its Cloud start stalled
/// (cloudStartProgress.ts `stalled`), carried to the chat that start opens on its machine. On success
/// the host closes this tab (CloudStartChat `origin.close`), so the page keeps the draft in the
/// agent panes' shared `localStorage` under the start's key (`cloud.startChat {key}`), and the
/// opened chat's page, whose handshake names the same key (`cloudStartKey`, the seed's), takes it
/// into its composer. A start that fails, or runs on this Mac instead, drops it: the draft is still
/// in this tab's composer. Keyed by the start, never by its prompt text.
///
/// The handoff has an order: the host reports its `opening` step before it opens the chat, and the
/// source composer takes no edit from then (cloudStartProgress.ts `cloudStartLocksComposer`), so its
/// last write comes before the opened chat reads. A write that still lands after that read (the push
/// on its way while the person typed) reaches the opened chat as a `storage` event while it follows
/// the key (`followCloudStartCarry`).
///
/// One `localStorage` item per pane and start (`cmux.cloudStart.carry.<key>.<source>`), never one
/// shared object: panes run in separate processes, and a read-modify-write of a shared object would
/// let one pane's write delete another's. Two panes that send the same prompt with the same options
/// get the same key (cloudRun.ts `cloudStartKeys`) and the host opens one chat for it
/// (`cloud-start-chat-<key>`): it takes both panes' drafts.
///
/// Only chips that carry their own content go: a chip that names a file on this Mac (`path`, a file
/// the app saved under Chat Uploads) means nothing on the Cloud machine, so it stays, its place in
/// the text goes, and the opened chat says how many stayed (`left`). A chip that goes keeps its place
/// (the editor's `U+FFFC<id>U+FFFC` token).
/// Leo, 2026-11-09: "I can't click into the composer at all to, like potentially type other stuff
/// while it's doing that initial load situation."

import { inlineTokenSpans, type ComposerAttachment } from "./attachments";

/// `text` without the places (tokens) of the chips in `staying`, read against all of `chips` as the
/// composer reads its draft, so the person's own U+FFFC and the other chips' places stay as they are.
function withoutPlaces(text: string, chips: readonly ComposerAttachment[], staying: ReadonlySet<string>): string {
  const ids = new Set(chips.map((chip) => chip.id));
  const spans = inlineTokenSpans(text, (id) => ids.has(id)).filter((span) => span.known && staying.has(span.id));
  let out = "";
  let at = 0;
  for (const span of spans) {
    out += text.slice(at, span.from);
    at = span.to;
  }
  return out + text.slice(at);
}

export type CloudStartCarryStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
  removeItem(name: string): void;
  readonly length: number;
  key(index: number): string | null;
};

export type CloudStartDraft = { text: string; attachments: ComposerAttachment[] };
type Entry = CloudStartDraft & { at: number; left: number };
/// What the opened chat takes: the drafts joined, how many chips stayed on this Mac, and each
/// source's entry (`parts`), so a later write of one replaces only its part.
export type CloudStartCarried = CloudStartDraft & { left: number; parts: Map<string, Entry> };

const PREFIX = "cmux.cloudStart.carry.";
/// A carry older than this belongs to a start long settled: it is dropped when found.
const CLOUD_START_CARRY_TTL_MS = 24 * 60 * 60 * 1000;
/// How long the opened chat follows its key for a write that landed after it read.
export const CLOUD_START_CARRY_FOLLOW_MS = 15_000;

function pageStore(): CloudStartCarryStore | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

const keyPrefix = (key: string) => `${PREFIX}${encodeURIComponent(key)}.`;
const itemName = (key: string, source: string) => `${keyPrefix(key)}${encodeURIComponent(source)}`;

/// A draft with nothing in it carries nothing.
export function draftIsEmpty(draft: CloudStartDraft): boolean {
  return !draft.text.trim() && draft.attachments.length === 0;
}

/// Two drafts hold the same thing: the same text and the same chips, in order, by id.
export function sameDraft(a: CloudStartDraft, b: CloudStartDraft): boolean {
  return (
    a.text === b.text &&
    a.attachments.length === b.attachments.length &&
    a.attachments.every((attachment, index) => attachment.id === b.attachments[index]?.id)
  );
}

/// A chip whose content is its own (bytes or text) goes to the Cloud machine as is, without its
/// Mac-only fields. One that only names a file on this Mac stays (undefined).
function carriedChip(attachment: ComposerAttachment): ComposerAttachment | undefined {
  const ownContent = attachment.data !== undefined || attachment.text !== undefined;
  if (!ownContent || attachment.saved) return undefined;
  const { path: _path, originalPath: _originalPath, originalName: _originalName, ...chip } = attachment;
  return chip;
}

/// `draft` as it goes: the chips that carry (none when `withChips` is off), and its text without the
/// places of the chips that stay (`withoutPlaces`), so a carried chip's token stays where it was.
function carriedDraft(draft: CloudStartDraft, withChips = true): CloudStartDraft & { left: number } {
  const kept = draft.attachments.filter((attachment) => !attachment.shellRun);
  const attachments = withChips ? kept.flatMap((attachment) => carriedChip(attachment) ?? []) : [];
  const going = new Set(attachments.map((attachment) => attachment.id));
  const staying = new Set(kept.filter((attachment) => !going.has(attachment.id)).map((attachment) => attachment.id));
  const text = staying.size ? withoutPlaces(draft.text, kept, staying) : draft.text;
  return { text, attachments, left: staying.size };
}

function readEntry(raw: string | null): Entry | undefined {
  if (!raw) return undefined;
  try {
    const entry = JSON.parse(raw) as Partial<Entry> | null;
    if (!entry || typeof entry.at !== "number") return undefined;
    return {
      text: typeof entry.text === "string" ? entry.text : "",
      attachments: Array.isArray(entry.attachments) ? entry.attachments : [],
      left: typeof entry.left === "number" ? entry.left : 0,
      at: entry.at,
    };
  } catch {
    return undefined;
  }
}

/// The carry of `parts`, oldest write first.
function joined(parts: Map<string, Entry>): CloudStartCarried {
  const sorted = [...parts.values()].sort((a, b) => a.at - b.at);
  return {
    text: sorted
      .map((entry) => entry.text)
      .filter((text) => text.trim())
      .join("\n\n"),
    attachments: sorted.flatMap((entry) => entry.attachments),
    left: sorted.reduce((sum, entry) => sum + entry.left, 0),
    parts: new Map(parts),
  };
}

export function cloudStartCarry(store: CloudStartCarryStore | undefined = pageStore(), now: () => number = Date.now) {
  const remove = (name: string) => {
    try {
      store?.removeItem(name);
    } catch {
      // A store that refuses keeps the entry until its TTL.
    }
  };
  const fresh = (entry: Entry | undefined) =>
    entry && now() - entry.at < CLOUD_START_CARRY_TTL_MS ? entry : undefined;
  return {
    /// Keeps `draft` as `source`'s for start `key`, writing only that pane's own item; an empty draft
    /// keeps nothing. A store too full for the chips' bytes keeps the text, the chips counted as left.
    save(key: string, source: string, draft: CloudStartDraft): void {
      if (!store) return;
      const name = itemName(key, source);
      const carried = carriedDraft(draft);
      if (!carried.text.trim() && carried.attachments.length === 0 && carried.left === 0) {
        remove(name);
        return;
      }
      const at = now();
      try {
        store.setItem(name, JSON.stringify({ ...carried, at }));
        return;
      } catch {
        // Too full for the bytes: the text alone, below.
      }
      try {
        store.setItem(name, JSON.stringify({ ...carriedDraft(draft, false), at }));
      } catch {
        remove(name);
      }
    },
    /// Every draft kept for start `key`, joined, oldest first; they are gone from the store after.
    take(key: string): CloudStartCarried | undefined {
      if (!store) return undefined;
      const prefix = keyPrefix(key);
      const names: string[] = [];
      try {
        for (let index = 0; index < store.length; index++) {
          const name = store.key(index);
          if (name?.startsWith(prefix)) names.push(name);
        }
      } catch {
        return undefined;
      }
      const parts = new Map<string, Entry>();
      for (const name of names) {
        const entry = fresh(readEntry(store.getItem(name)));
        remove(name);
        if (entry) parts.set(decodeURIComponent(name.slice(prefix.length)), entry);
      }
      if (parts.size === 0) return undefined;
      const carried = joined(parts);
      return draftIsEmpty(carried) && carried.left === 0 ? undefined : carried;
    },
    /// What `name` (a `storage` event's item) holds for start `key` now, when it is a source's write
    /// newer than `seenAt`: taken from the store. Undefined for another item, or nothing newer.
    takeWrite(key: string, name: string, seen: (source: string) => number | undefined): [string, Entry] | undefined {
      const prefix = keyPrefix(key);
      if (!store || !name.startsWith(prefix)) return undefined;
      const source = decodeURIComponent(name.slice(prefix.length));
      const entry = fresh(readEntry(store.getItem(name)));
      const before = seen(source);
      if (!entry || (before !== undefined && entry.at <= before)) return undefined;
      remove(name);
      return [source, entry];
    },
    /// `source`'s start `key` ended here (failed, or runs on this Mac): its draft stays in its tab.
    drop(key: string, source: string): void {
      remove(itemName(key, source));
    },
  };
}

export type CloudStartCarry = ReturnType<typeof cloudStartCarry>;

/// The opened chat's side after it took `carried`: for CLOUD_START_CARRY_FOLLOW_MS, a source's write
/// for `key` that lands later (a `storage` event, which every other page of the store gets) replaces
/// that source's part. `apply` gets the carry as it is now and the one it replaces, and decides
/// whether the composer still holds that one. Returns the stop.
export function followCloudStartCarry(
  target: Pick<Window, "addEventListener" | "removeEventListener">,
  carry: CloudStartCarry,
  key: string,
  carried: CloudStartCarried,
  apply: (next: CloudStartCarried, previous: CloudStartCarried) => void,
  ms: number = CLOUD_START_CARRY_FOLLOW_MS,
): () => void {
  let current = carried;
  const onStorage = (event: Event) => {
    const name = (event as StorageEvent).key;
    if (typeof name !== "string") return;
    const write = carry.takeWrite(key, name, (source) => current.parts.get(source)?.at);
    if (!write) return;
    const parts = new Map(current.parts);
    parts.set(write[0], write[1]);
    const previous = current;
    current = joined(parts);
    apply(current, previous);
  };
  target.addEventListener("storage", onStorage);
  const stop = () => {
    clearTimeout(timer);
    target.removeEventListener("storage", onStorage);
  };
  const timer = setTimeout(stop, ms);
  return stop;
}

/// The source page's side of a carry, for one attempt at a time (App.tsx): `begin` as an attempt
/// goes, `stalled` when it stalls, `edited` on each change of the composer while it is stalled,
/// `ended` with the host's answer. At the stall the composer still holds the sent prompt: it is taken
/// out (the chat shows it sent, and a failure puts it back ahead of what was typed), so what the
/// person types after is the next message, carried whole. A late success leaves the carry for the
/// opened chat. `source` names this pane's item under the key.
export function cloudStartCarrySource(carry: CloudStartCarry, source: string = crypto.randomUUID()) {
  /// The attempt out now: its key, and whether it stalled yet. A retry under the same key is a new
  /// attempt (`begin`), which stalls and carries on its own.
  let attempt: { key: string; stalled: boolean } | undefined;
  return {
    begin(startKey: string): void {
      attempt = { key: startKey, stalled: false };
    },
    /// The attempt of `startKey` stalled with `draft` in the composer and `sent` its prompt, once per
    /// attempt. Answers the prompt to hold for a failure when the composer should be emptied of it.
    stalled(startKey: string, draft: CloudStartDraft, sent: CloudStartDraft): CloudStartDraft | undefined {
      if (attempt?.key !== startKey || attempt.stalled) return undefined;
      attempt.stalled = true;
      if (sameDraft(draft, sent)) return draftIsEmpty(sent) ? undefined : sent;
      // Not the sent prompt (a page's start leaves the chat composer empty): what is there now is
      // the person's, and goes with the start too.
      carry.save(startKey, source, draft);
      return undefined;
    },
    /// The composer changed: its draft (read only while a stalled attempt is out) is kept for it.
    edited(read: () => CloudStartDraft | undefined): void {
      if (!attempt?.stalled) return;
      const draft = read();
      if (draft) carry.save(attempt.key, source, draft);
    },
    /// The host answered the attempt of `startKey`: opened (`ok`), the carry stays for the opened
    /// chat; anything else drops this pane's, the draft being still here.
    ended(startKey: string, ok: boolean): void {
      if (attempt?.key !== startKey) return;
      attempt = undefined;
      if (!ok) carry.drop(startKey, source);
    },
    /// Another chat shows here: this page stops writing, and leaves what it kept to its start.
    reset(): void {
      attempt = undefined;
    },
  };
}
