import type { ComposerAttachment } from "./attachments";

/// What the person typed or pasted into the composer while a Cloud start was out (Leo, 2026-11-09:
/// "I can't click into the composer at all to, like potentially type other stuff while it's doing
/// that initial load situation"). The host closes this tab once the chat opens on its machine and
/// opens the chat in a new tab with only the sent prompt (CloudStartChat.swift `open`), so the
/// sending page keeps the draft here, by its start's key, and the started chat's page takes it into
/// its composer as a draft when its handshake seeds that prompt. It is never sent by itself.
///
/// The store is the pages' `localStorage`: every agent pane shares one web data store
/// (AgentPaneView+Warmup `sharedDataStore`), the Cloud chat's page included, so it outlives the
/// closed tab (as `cloudStartKeys` does) but not an app relaunch.
export type CloudStartDraftStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
  removeItem(name: string): void;
};

export type CloudStartDraft = { text: string; attachments: ComposerAttachment[] };

type Kept = CloudStartDraft & { task: string; at: number };

/// The page's store; undefined where there is none (a page with storage off).
export function cloudStartDraftStore(): CloudStartDraftStore | undefined {
  try {
    return globalThis.localStorage ?? undefined;
  } catch {
    return undefined;
  }
}

const CARRY = "cmux.cloudStart.drafts";
/// A start that waits this long has long ended: its draft is old and goes.
export const CLOUD_START_DRAFT_TTL_MS = 6 * 60 * 60 * 1000;

function read(store: CloudStartDraftStore, now: number): Record<string, Kept> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(store.getItem(CARRY) ?? "{}");
  } catch {
    return {};
  }
  const kept: Record<string, Kept> = {};
  if (!parsed || typeof parsed !== "object") return kept;
  for (const [key, value] of Object.entries(parsed as Record<string, Partial<Kept>>)) {
    if (
      typeof value?.task === "string" &&
      typeof value.text === "string" &&
      Array.isArray(value.attachments) &&
      typeof value.at === "number" &&
      now - value.at < CLOUD_START_DRAFT_TTL_MS
    )
      kept[key] = value as Kept;
  }
  return kept;
}

function write(store: CloudStartDraftStore, kept: Record<string, Kept>): void {
  if (Object.keys(kept).length === 0) {
    store.removeItem(CARRY);
    return;
  }
  try {
    store.setItem(CARRY, JSON.stringify(kept));
  } catch {
    // Over the store's quota (large pasted images): the words still go; the chips stay on this page.
    const words = Object.fromEntries(Object.entries(kept).map(([key, value]) => [key, { ...value, attachments: [] }]));
    try {
      store.setItem(CARRY, JSON.stringify(words));
    } catch {
      // Nothing fits: the draft stays in this page's composer until the tab closes.
    }
  }
}

/// Whether a draft holds anything the person would miss.
export function holdsDraft(draft: CloudStartDraft | undefined): draft is CloudStartDraft {
  return Boolean(draft && (draft.text.trim() || draft.attachments.length));
}

/// The draft without the start's own prompt in front of it: a start resent after a sign-in leaves
/// the prompt in the composer (only the composer's own Send empties it), and the started chat
/// already has it as its first message.
export function withoutPrompt(draft: CloudStartDraft, task: string): CloudStartDraft {
  if (!task.trim()) return draft;
  if (draft.text === task) return { ...draft, text: "" };
  if (draft.text.startsWith(`${task}\n\n`)) return { ...draft, text: draft.text.slice(task.length + 2) };
  return draft;
}

/// Keeps start `key`'s draft (its prompt `task`), or drops it when the composer is empty again.
export function keepCloudStartDraft(
  store: CloudStartDraftStore,
  key: string,
  task: string,
  shown: CloudStartDraft,
  now = Date.now(),
): void {
  const kept = read(store, now);
  const draft = withoutPrompt(shown, task);
  if (holdsDraft(draft)) kept[key] = { task, text: draft.text, attachments: draft.attachments, at: now };
  else delete kept[key];
  write(store, kept);
}

/// Start `key` ended here (it failed, or ran on this Mac): its draft is in this composer, not elsewhere.
export function dropCloudStartDraft(store: CloudStartDraftStore, key: string, now = Date.now()): void {
  const kept = read(store, now);
  if (!(key in kept)) return;
  delete kept[key];
  write(store, kept);
}

/// The started chat's page, whose handshake seeded `task`: the newest draft kept for a start of that
/// prompt, taken once (another chat opened with the same words gets none).
export function takeCloudStartDraft(
  store: CloudStartDraftStore,
  task: string,
  now = Date.now(),
): CloudStartDraft | undefined {
  const kept = read(store, now);
  let found: [string, Kept] | undefined;
  for (const entry of Object.entries(kept))
    if (entry[1].task === task && (!found || entry[1].at > found[1].at)) found = entry;
  if (!found) return undefined;
  delete kept[found[0]];
  write(store, kept);
  return { text: found[1].text, attachments: found[1].attachments };
}

/// A failed start's prompt went back in front of what was typed meanwhile (ComposerHandle.restore):
/// the prompt alone, for a Retry or Run on This Mac that sends it, when the composer still holds
/// exactly that pair. Undefined once the person changed it: then what shows is what goes.
export function promptBeforeTyped(
  composer: CloudStartDraft,
  typed: CloudStartDraft,
): { prompt: CloudStartDraft; typed: CloudStartDraft } | undefined {
  if (!holdsDraft(typed)) return undefined;
  const tail = typed.text.trim() ? `\n\n${typed.text}` : "";
  if (tail && !composer.text.endsWith(tail)) return undefined;
  const ids = new Set(typed.attachments.map((chip) => chip.id));
  if (typed.attachments.some((chip) => !composer.attachments.some((held) => held.id === chip.id))) return undefined;
  return {
    prompt: {
      text: tail ? composer.text.slice(0, -tail.length) : composer.text,
      attachments: composer.attachments.filter((chip) => !ids.has(chip.id)),
    },
    typed,
  };
}
