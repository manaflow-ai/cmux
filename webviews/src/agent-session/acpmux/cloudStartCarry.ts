/// What the person typed in a new chat's composer after its Cloud start stalled
/// (cloudStartProgress.ts `stalled`), carried to the chat that start opens on its machine. On success
/// the host closes this tab (CloudStartChat `origin.close`), so the page keeps the draft in the
/// agent panes' shared `localStorage` under the start's key (`cloud.startChat {key}`), and the
/// opened chat's page, whose handshake names the same key (`cloudStartKey`, the seed's), takes it
/// once into its composer. A start that fails, or runs on this Mac instead, drops it: the draft is
/// still in this tab's composer. Keyed by the start, never by its prompt text.
///
/// The key is what the host opens the chat under (`cloud-start-chat-<key>`): two panes that send the
/// same prompt with the same options get the same key (cloudRun.ts `cloudStartKeys`) and so the same
/// opened chat. Each pane keeps its own entry under the key (its `source`), and the opened chat takes
/// them all, so neither pane's words overwrite the other's.
///
/// Only chips that carry their own content go: a chip that names a file on this Mac (`path`, a file
/// the app saved under Chat Uploads) means nothing on the Cloud machine, so it stays, and the opened
/// chat says how many stayed (`left`).
/// Leo, 2026-11-09: "I can't click into the composer at all to, like potentially type other stuff
/// while it's doing that initial load situation."

import { INLINE_ATTACHMENT_MARK, type ComposerAttachment } from "./attachments";

export type CloudStartCarryStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
};

export type CloudStartDraft = { text: string; attachments: ComposerAttachment[] };
/// What the opened chat takes: the drafts joined, and how many chips stayed on this Mac.
export type CloudStartCarried = CloudStartDraft & { left: number };

const CLOUD_START_CARRY = "cmux.cloudStart.carry";
/// A carry older than this belongs to a start long settled: it is dropped on the next write.
const CLOUD_START_CARRY_TTL_MS = 24 * 60 * 60 * 1000;

type Entry = CloudStartDraft & { at: number; left: number };
type Kept = Record<string, Record<string, Entry>>;

function pageStore(): CloudStartCarryStore | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

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

/// A chip whose content is its own (bytes or text) goes to the Cloud machine as is; its Mac-only
/// fields go. One that only names a file on this Mac stays (undefined).
function carriedChip(attachment: ComposerAttachment): ComposerAttachment | undefined {
  if (attachment.shellRun) return undefined;
  const ownContent = attachment.data !== undefined || attachment.text !== undefined;
  if (!ownContent || attachment.saved) return undefined;
  const { path: _path, originalPath: _originalPath, originalName: _originalName, ...chip } = attachment;
  return chip;
}

/// `draft` as it goes: the chips that carry, and its text without the places of inline chips that
/// stay (their marks are in the text in the order of the inline chips).
function carriedDraft(draft: CloudStartDraft): CloudStartDraft & { left: number } {
  const kept = draft.attachments.filter((attachment) => !attachment.shellRun);
  const inline = kept.filter((attachment) => attachment.inline);
  let mark = 0;
  const text = draft.text.replaceAll(INLINE_ATTACHMENT_MARK, () => {
    const chip = inline[mark++];
    return chip && carriedChip(chip) ? INLINE_ATTACHMENT_MARK : "";
  });
  const attachments = kept.flatMap((attachment) => carriedChip(attachment) ?? []);
  return { text, attachments, left: kept.length - attachments.length };
}

export function cloudStartCarry(store: CloudStartCarryStore | undefined = pageStore(), now: () => number = Date.now) {
  const read = (): Kept => {
    if (!store) return {};
    try {
      const value = JSON.parse(store.getItem(CLOUD_START_CARRY) ?? "{}") as unknown;
      return value && typeof value === "object" && !Array.isArray(value) ? (value as Kept) : {};
    } catch {
      return {};
    }
  };
  const write = (kept: Kept): boolean => {
    if (!store) return false;
    try {
      store.setItem(CLOUD_START_CARRY, JSON.stringify(kept));
      return true;
    } catch {
      return false;
    }
  };
  const fresh = (kept: Kept, at: number) => {
    for (const [key, sources] of Object.entries(kept)) {
      if (!sources || typeof sources !== "object") {
        delete kept[key];
        continue;
      }
      for (const [source, entry] of Object.entries(sources))
        if (!entry || typeof entry.at !== "number" || at - entry.at >= CLOUD_START_CARRY_TTL_MS) delete sources[source];
      if (Object.keys(sources).length === 0) delete kept[key];
    }
  };
  const remove = (kept: Kept, key: string, source: string) => {
    const sources = kept[key];
    if (!sources) return;
    delete sources[source];
    if (Object.keys(sources).length === 0) delete kept[key];
  };
  return {
    /// Keeps `draft` as `source`'s for start `key`, replacing what it kept; an empty draft keeps
    /// nothing. A store too full for the chips' bytes keeps the text, the chips counted as left.
    save(key: string, source: string, draft: CloudStartDraft): void {
      const kept = read();
      const at = now();
      fresh(kept, at);
      const { text, attachments: chips, left } = carriedDraft(draft);
      if (!text.trim() && chips.length === 0 && left === 0) {
        remove(kept, key, source);
        write(kept);
        return;
      }
      kept[key] = { ...kept[key], [source]: { text, attachments: chips, at, left } };
      if (write(kept)) return;
      const plain = carriedDraft({
        text,
        attachments: chips.map((chip) => ({ ...chip, data: undefined, text: undefined })),
      });
      kept[key]![source] = { text: plain.text, attachments: [], at, left: left + chips.length };
      if (!write(kept)) {
        remove(kept, key, source);
        write(kept);
      }
    },
    /// Every draft kept for start `key`, in the order they were last written, joined; once: they are
    /// gone from the store after.
    take(key: string): CloudStartCarried | undefined {
      const kept = read();
      const sources = kept[key];
      if (!sources) return undefined;
      delete kept[key];
      write(kept);
      const at = now();
      const entries = Object.values(sources)
        .filter((entry) => entry && typeof entry.at === "number" && at - entry.at < CLOUD_START_CARRY_TTL_MS)
        .sort((a, b) => a.at - b.at);
      const texts = entries
        .map((entry) => (typeof entry.text === "string" ? entry.text : ""))
        .filter((text) => text.trim());
      const attachments = entries.flatMap((entry) => (Array.isArray(entry.attachments) ? entry.attachments : []));
      const left = entries.reduce((sum, entry) => sum + (typeof entry.left === "number" ? entry.left : 0), 0);
      const carried = { text: texts.join("\n\n"), attachments, left };
      return draftIsEmpty(carried) && left === 0 ? undefined : carried;
    },
    /// `source`'s start `key` ended here (failed, or runs on this Mac): its draft stays in its tab.
    drop(key: string, source: string): void {
      const kept = read();
      if (!kept[key]?.[source]) return;
      remove(kept, key, source);
      write(kept);
    },
  };
}

export type CloudStartCarry = ReturnType<typeof cloudStartCarry>;

/// The source page's side of a carry, for one attempt at a time (App.tsx): `stalled` when the start
/// stalls, `edited` on each change of the composer while it is stalled, `ended` with the host's
/// answer. At the stall the composer still holds the sent prompt: it is taken out (the chat shows it
/// sent, and a failure puts it back ahead of what was typed), so what the person types after is the
/// next message, carried whole. A late success leaves the carry for the opened chat. `source` names
/// this pane's entry under the key.
export function cloudStartCarrySource(carry: CloudStartCarry, source: string = crypto.randomUUID()) {
  /// The attempt out now: its key, and whether it stalled yet. A retry under the same key is a new
  /// attempt (`begin`), which stalls and carries on its own.
  let attempt: { key: string; stalled: boolean } | undefined;
  return {
    /// An attempt of start `startKey` went to the host.
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
