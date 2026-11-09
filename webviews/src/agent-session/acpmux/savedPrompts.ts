// Saved prompts: a message saved under a name (the prompt's or reply's Save as Prompt), offered in
// the composer's `/` menu next to the chat's commands. Picking one writes its text in place of the
// `/word`, its variables filled in. acpmux keeps them (`_acpmux/prompts_list`, `_acpmux/prompts_save`,
// `_acpmux/prompts_delete`, crates/acpmux/src/prompts.rs) beside the prompts cmux-next.json names
// under `agentPane.savedPrompts`, so every chat and pane on the machine lists the same ones. The pane
// keeps one copy for the page: read when the `/` menu opens (once per opening, never per key) and
// after each save, so a prompt saved in another chat shows the next time the menu opens here.
import { useSyncExternalStore } from "react";
import type { SlashCommand } from "./slashCommands";

export type SavedPrompt = {
  name: string;
  text: string;
  /// `settings`: from cmux-next.json, read-only here.
  source: "saved" | "settings";
  updatedAt?: number;
};

/// How the store reaches acpmux: the pane's client (App.tsx), absent in a page without one.
export type SavedPromptsTransport = {
  list(): Promise<unknown>;
  save(name: string, text: string): Promise<unknown>;
  remove(name: string): Promise<unknown>;
};

/// The longest name acpmux takes (prompts.rs).
export const PROMPT_NAME_MAX = 64;

let transport: SavedPromptsTransport | undefined;
let prompts: readonly SavedPrompt[] = [];
/// The read in flight, so a menu opened twice in a row asks once.
let reading: Promise<void> | undefined;
const listeners = new Set<() => void>();
const emit = () => {
  for (const listener of listeners) listener();
};

/// The rows of a `_acpmux/prompts_list` answer (or one save's `prompt`), the malformed ones left out.
export function promptsFrom(value: unknown): SavedPrompt[] {
  const list =
    value && typeof value === "object" && "prompts" in value ? (value as { prompts: unknown }).prompts : value;
  if (!Array.isArray(list)) return [];
  const rows: SavedPrompt[] = [];
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const { name, text, source, updatedAt } = entry as Record<string, unknown>;
    if (typeof name !== "string" || !name.trim() || typeof text !== "string" || !text.trim()) continue;
    rows.push({
      name: name.trim(),
      text,
      source: source === "settings" ? "settings" : "saved",
      ...(typeof updatedAt === "number" ? { updatedAt } : {}),
    });
  }
  return rows;
}

/// The pane's acpmux connection, or none. A page without one (a gallery, a test) keeps saves in the page.
/// Another connection (a reconnect, another machine's acpmux) starts from no list: the old one's
/// prompts are never shown or inserted, and its answers still on their way are dropped.
export function setSavedPromptsTransport(next: SavedPromptsTransport | undefined): void {
  if (next === transport) return;
  transport = next;
  reading = undefined;
  if (prompts.length) {
    prompts = [];
    emit();
  }
  if (next) void refreshSavedPrompts();
}

/// Saves and deletes begun or ended: a list read while one was out may not hold it.
let changes = 0;

/// Reads the list again from acpmux; the copy shown stays until the answer comes, and stays on a refusal.
/// An answer read while a save or delete was out is dropped and the list read again, so it never
/// takes back a save the page already shows.
export function refreshSavedPrompts(): Promise<void> {
  const via = transport;
  if (!via) return Promise.resolve();
  if (reading) return reading;
  const at = changes;
  let stale = false;
  const read = via.list().then(
    (reply) => {
      if (via !== transport) return;
      if (at !== changes) return void (stale = true);
      prompts = promptsFrom(reply);
      emit();
    },
    () => undefined,
  );
  const settled = read.finally(() => {
    if (reading === settled) reading = undefined;
  });
  reading = settled;
  return settled.then(() => (stale && via === transport ? refreshSavedPrompts() : undefined));
}

const sameName = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/// Saves `text` under `name`, replacing a saved prompt of that name. Rejects with acpmux's reason.
export async function savePrompt(name: string, text: string): Promise<void> {
  const trimmed = name.trim();
  const row: SavedPrompt = { name: trimmed, text, source: "saved", updatedAt: Date.now() };
  if (transport) {
    const via = transport;
    changes += 1;
    try {
      const reply = await via.save(trimmed, text);
      const saved = promptsFrom([(reply as { prompt?: unknown } | undefined)?.prompt])[0] ?? row;
      if (via !== transport) return;
      prompts = withPrompt(prompts, saved);
    } finally {
      changes += 1;
    }
  } else prompts = withPrompt(prompts, row);
  emit();
}

/// Deletes the saved prompt `name`. Rejects with acpmux's reason (a cmux-next.json prompt is removed there).
export async function deletePrompt(name: string): Promise<void> {
  const via = transport;
  if (via) {
    changes += 1;
    try {
      await via.remove(name);
    } finally {
      changes += 1;
    }
  }
  if (via !== transport) return;
  prompts = prompts.filter((prompt) => !sameName(prompt.name, name));
  emit();
}

/// `list` with `row` in its name's place (a saved row replaces a settings one of the same name), by name.
export function withPrompt(list: readonly SavedPrompt[], row: SavedPrompt): SavedPrompt[] {
  return [...list.filter((prompt) => !sameName(prompt.name, row.name)), row].sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { sensitivity: "base" }),
  );
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => prompts;
/// The list as the page holds it now (outside render).
export const savedPromptsNow = (): readonly SavedPrompt[] => prompts;
export const useSavedPrompts = (): readonly SavedPrompt[] => useSyncExternalStore(subscribe, snapshot, snapshot);
/// Tests and galleries: the list as if acpmux had answered it.
export function seedSavedPrompts(next: readonly SavedPrompt[]): void {
  prompts = [...next];
  emit();
}

/// A name as the `/` word types it: lower case, words joined by `-` (`Review PR` is `/review-pr`).
export function promptSlug(name: string): string {
  return name
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}_.]+/gu, "-")
    .replace(/^-+|-+$/g, "");
}

/// The `/` menu's rows for the saved prompts: `source: "saved"`, the slug as the name, the first
/// line as the description, the text as `body`. A slug two prompts share goes to the first.
export function savedPromptCommands(list: readonly SavedPrompt[]): SlashCommand[] {
  const seen = new Set<string>();
  const commands: SlashCommand[] = [];
  for (const prompt of list) {
    const name = promptSlug(prompt.name);
    if (!name || seen.has(name)) continue;
    seen.add(name);
    commands.push({ name, description: firstLine(prompt.text), source: "saved", body: prompt.text });
  }
  return commands;
}

const firstLine = (text: string) => text.trim().split("\n", 1)[0]!.slice(0, 120);

/// A name to offer when saving `text`: its first words, at most five, cut to the name's limit.
export function suggestedName(text: string): string {
  const words = firstLine(text.replace(/^\/\S+\s*/, ""))
    .replace(/[`*_#>[\]]/g, "")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 5)
    .join(" ");
  return words.slice(0, PROMPT_NAME_MAX).trim();
}

/// What a prompt's variables are filled with: `{{date}}`, `{{time}}`, `{{folder}}`, `{{cwd}}` and
/// `{{branch}}` from the chat; any other name stays for the person to type over.
export type PromptContext = { cwd?: string; branch?: string; now?: Date };

const VARIABLE = /\{\{\s*([A-Za-z][\w-]*)\s*\}\}/g;

const pad = (value: number) => String(value).padStart(2, "0");

/// `text` with the variables the chat knows filled in, and the first one left (its range in the
/// result), which the composer selects so typing replaces it.
/// Where the word the caret at `at` sits in ends: a saved prompt picked from `/sta|ndup` replaces the
/// whole `/standup`, as a command's completion does.
export const wordEnd = (value: string, at: number): number => at + (/^\S*/.exec(value.slice(at))?.[0].length ?? 0);

export function fillPrompt(text: string, context: PromptContext): { text: string; open?: [number, number] } {
  const now = context.now ?? new Date();
  const folder = context.cwd?.replace(/\/+$/, "").split("/").pop() || undefined;
  const known: Record<string, string | undefined> = {
    date: `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`,
    time: `${pad(now.getHours())}:${pad(now.getMinutes())}`,
    folder,
    cwd: context.cwd || undefined,
    branch: context.branch || undefined,
  };
  let open: [number, number] | undefined;
  let out = "";
  let last = 0;
  for (const match of text.matchAll(VARIABLE)) {
    out += text.slice(last, match.index);
    last = match.index + match[0].length;
    const name = match[1]!.toLowerCase();
    // Own keys only: `{{constructor}}` is a variable left open, not Object's.
    const value = Object.hasOwn(known, name) ? known[name as keyof typeof known] : undefined;
    if (value !== undefined) out += value;
    else {
      if (!open) open = [out.length, out.length + match[0].length];
      out += match[0];
    }
  }
  out += text.slice(last);
  return open ? { text: out, open } : { text: out };
}
