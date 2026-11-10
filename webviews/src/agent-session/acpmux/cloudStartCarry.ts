/// What the person typed in a new chat's composer after its Cloud start stalled
/// (cloudStartProgress.ts `stalled`), carried to the chat that start opens on its machine. On success
/// the host closes this tab (CloudStartChat `origin.close`), so the page keeps the draft in the
/// agent panes' shared `localStorage` under the start's key (`cloud.startChat {key}`), and the
/// opened chat's page, whose handshake names the same key (`cloudStartKey`, the seed's), takes it
/// once into its composer. A start that fails, or runs on this Mac instead, drops it: the draft is
/// still in this tab's composer. Keyed by the start, never by its prompt, so two starts with the
/// same prompt never take each other's draft, and an attachment-only draft carries as well.
/// Leo, 2026-11-09: "I can't click into the composer at all to, like potentially type other stuff
/// while it's doing that initial load situation."

import type { ComposerAttachment } from "./attachments";

export type CloudStartCarryStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
};

export type CloudStartDraft = { text: string; attachments: ComposerAttachment[] };

const CLOUD_START_CARRY = "cmux.cloudStart.carry";
/// A carry older than this belongs to a start long settled: it is dropped on the next write.
const CLOUD_START_CARRY_TTL_MS = 24 * 60 * 60 * 1000;

type Kept = Record<string, CloudStartDraft & { at: number }>;

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
    for (const [key, entry] of Object.entries(kept))
      if (!entry || typeof entry.at !== "number" || at - entry.at >= CLOUD_START_CARRY_TTL_MS) delete kept[key];
  };
  return {
    /// Keeps `draft` for start `key`, replacing what was kept; an empty draft keeps nothing. A store
    /// too full for the files' bytes keeps the text and the chips that carry no bytes.
    save(key: string, draft: CloudStartDraft): void {
      const kept = read();
      const at = now();
      fresh(kept, at);
      if (draftIsEmpty(draft)) {
        if (key in kept) {
          delete kept[key];
          write(kept);
        }
        return;
      }
      kept[key] = { text: draft.text, attachments: draft.attachments, at };
      if (write(kept)) return;
      const light = draft.attachments.filter((attachment) => attachment.data === undefined);
      kept[key] = { text: draft.text, attachments: light, at };
      if (!write(kept)) {
        delete kept[key];
        write(kept);
      }
    },
    /// The draft kept for start `key`, once: it is gone from the store after.
    take(key: string): CloudStartDraft | undefined {
      const kept = read();
      const entry = kept[key];
      if (!entry) return undefined;
      delete kept[key];
      write(kept);
      if (now() - entry.at >= CLOUD_START_CARRY_TTL_MS) return undefined;
      const text = typeof entry.text === "string" ? entry.text : "";
      const attachments = Array.isArray(entry.attachments) ? entry.attachments : [];
      const draft = { text, attachments };
      return draftIsEmpty(draft) ? undefined : draft;
    },
    /// Start `key` ended here (failed, or runs on this Mac): its draft stays in this tab, so none carries.
    drop(key: string): void {
      const kept = read();
      if (!(key in kept)) return;
      delete kept[key];
      write(kept);
    },
  };
}

export type CloudStartCarry = ReturnType<typeof cloudStartCarry>;

/// The source page's side of a carry, for one start at a time (App.tsx): `stalled` when the start
/// stalls, `edited` on each change of the composer while it is stalled, `ended` with the host's
/// answer. At the stall the composer still holds the sent prompt: it is taken out (the chat shows it
/// sent, and a failure puts it back ahead of what was typed), so what the person types after is the
/// next message, carried whole. A late success leaves the carry for the opened chat.
export function cloudStartCarrySource(carry: CloudStartCarry) {
  let key: string | undefined;
  return {
    /// Start `startKey` stalled with `draft` in the composer and `sent` its prompt. Answers the prompt
    /// to hold for a failure when the composer should be emptied of it, else undefined.
    stalled(startKey: string, draft: CloudStartDraft, sent: CloudStartDraft): CloudStartDraft | undefined {
      key = startKey;
      if (sameDraft(draft, sent)) return draftIsEmpty(sent) ? undefined : sent;
      // Not the sent prompt (a page's start leaves the chat composer empty): what is there now is
      // the person's, and goes with the start too.
      carry.save(startKey, draft);
      return undefined;
    },
    /// The composer changed: its draft (read only while a stalled start is out) is kept for it.
    edited(read: () => CloudStartDraft | undefined): void {
      if (key === undefined) return;
      const draft = read();
      if (draft) carry.save(key, draft);
    },
    /// The host answered start `startKey`: opened (`ok`), the carry stays for the opened chat;
    /// anything else drops it, the draft being still here.
    ended(startKey: string, ok: boolean): void {
      if (key !== startKey) return;
      key = undefined;
      if (!ok) carry.drop(startKey);
    },
    /// Another chat shows here: this page stops writing, and leaves what it kept to its start.
    reset(): void {
      key = undefined;
    },
  };
}
