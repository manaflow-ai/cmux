// What the app hands the open conversation's composer (the native Home composer's intake, moved to
// the page): files by path (`home.attachFiles`, a viewer quote, a design mode card) and the selected
// message text as a quote (`home.replyToSelection`, the selection menu's Quote in Reply).
//
// Host → page (served while the page is mounted, pageCommands.ts):
//   home.messages.attach {files: [{token, name, mimeType, size}], group?} -> {attached, reason?}
//       The page reads each file from the host in chunks (`cmux.home.messages.compose.read {token,
//       offset}` -> {data: base64, size}) and adds it to the composer's tray, where it uploads as a
//       drop does. It answers once every file is read, so the host may then delete what it wrote.
//       `group` names the set, so a later `detach` takes it back (an edited or removed card).
//       reason: "noComposer" (no conversation shows, or its owner takes no files) | "unreadable".
//   home.messages.detach {group} -> {removed}
//   home.messages.quoteSelection {} -> {quoted}: the text selected in a message goes into the
//       composer as a Markdown quote; false when nothing in a message is selected.
import type { PageClient } from "../shared/pageClient";

export const HandoffOps = {
  attach: "home.messages.attach",
  detach: "home.messages.detach",
  quoteSelection: "home.messages.quoteSelection",
  read: "cmux.home.messages.compose.read",
} as const;

/** The composer the app's hand-off reaches (MessageComposer's handle). */
export interface ComposerTarget {
  /** False when its conversation's owner takes no files through this host. */
  readonly takesFiles: boolean;
  addFiles(files: Iterable<File>, group?: string): void;
  /** Takes back the files `group` added (their uploads stop); true when any went. */
  removeGroup(group: string): boolean;
  /** Puts `text` in the field as a quote, the caret after it; false when the field is not there. */
  quote(text: string): boolean;
}

/** One file the host offers by token. */
export interface HostFile {
  token: string;
  name: string;
  mimeType: string;
  size: number;
}

type Json = Record<string, unknown>;
const record = (value: unknown): Json => (value && typeof value === "object" ? (value as Json) : {});
const GROUP = /^[\w.:-]{1,200}$/;

function hostFiles(value: unknown): HostFile[] | undefined {
  if (!Array.isArray(value) || value.length === 0) return undefined;
  const files: HostFile[] = [];
  for (const entry of value) {
    const raw = record(entry);
    if (typeof raw.token !== "string" || !raw.token || typeof raw.name !== "string") return undefined;
    const size = typeof raw.size === "number" && Number.isFinite(raw.size) && raw.size >= 0 ? raw.size : undefined;
    if (size === undefined) return undefined;
    files.push({
      token: raw.token,
      name: raw.name,
      mimeType: typeof raw.mimeType === "string" ? raw.mimeType : "",
      size,
    });
  }
  return files;
}

function decode(base64: string): Uint8Array<ArrayBuffer> {
  const text = atob(base64);
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes;
}

/** Reads one host file, chunk by chunk, into a File. Rejects when the host stops answering or a
 * chunk does not move forward. */
export async function readHostFile(client: Pick<PageClient, "call">, file: HostFile): Promise<File> {
  const chunks: Uint8Array<ArrayBuffer>[] = [];
  let offset = 0;
  // One chunk per call; the host says how many bytes it has (a file that grew or shrank since the
  // host listed it is read to its end as it is now).
  for (;;) {
    const answer = record(await client.call<unknown>(HandoffOps.read, { token: file.token, offset }));
    const data = typeof answer.data === "string" ? decode(answer.data) : undefined;
    const size = typeof answer.size === "number" ? answer.size : undefined;
    if (!data || size === undefined) throw new Error("unreadable");
    if (data.length) chunks.push(data);
    offset += data.length;
    if (offset >= size) break;
    if (data.length === 0) throw new Error("unreadable");
  }
  return new File(chunks, file.name, file.mimeType ? { type: file.mimeType } : {});
}

export async function attach(
  client: Pick<PageClient, "call">,
  composer: ComposerTarget | undefined,
  params: unknown,
): Promise<{ attached: boolean; reason?: string }> {
  const raw = record(params);
  const files = hostFiles(raw.files);
  if (!files) return { attached: false, reason: "noFiles" };
  if (!composer?.takesFiles) return { attached: false, reason: "noComposer" };
  const group = typeof raw.group === "string" && GROUP.test(raw.group) ? raw.group : undefined;
  let read: File[];
  try {
    read = await Promise.all(files.map((file) => readHostFile(client, file)));
  } catch {
    return { attached: false, reason: "unreadable" };
  }
  composer.addFiles(read, group);
  return { attached: true };
}

export function detach(composer: ComposerTarget | undefined, params: unknown): { removed: boolean } {
  const group = record(params).group;
  if (typeof group !== "string" || !GROUP.test(group)) return { removed: false };
  return { removed: composer?.removeGroup(group) ?? false };
}

/** The text selected in a message of the transcript (never in a field), or undefined. */
export function selectedMessageText(doc: Document): string | undefined {
  const selection = doc.getSelection();
  const text = selection?.toString() ?? "";
  if (!selection || selection.isCollapsed || !text.trim()) return undefined;
  const anchor = selection.anchorNode;
  const element = anchor?.nodeType === 1 ? (anchor as Element) : anchor?.parentElement;
  if (!element || element.closest(".mt-compose, input, textarea, [contenteditable]")) return undefined;
  if (!element.closest(".mt-scroller")) return undefined;
  return text;
}

export function quoteSelection(doc: Document, composer: ComposerTarget | undefined): { quoted: boolean } {
  const text = selectedMessageText(doc);
  if (!text || !composer) return { quoted: false };
  return { quoted: composer.quote(text) };
}
