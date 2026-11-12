// What a paste or a drop gives the message box (a port of HomeAttachmentIntake.swift and
// HomeComposerCheck.swift onto the web's DataTransfer):
// - Files attach. A file copied in a file manager also carries its name (or path) as text: that text
//   is not words to paste.
// - A paste with real text and no files is text: the field takes it. A string that is blank or only
//   one link (a browser's Copy Image adds the picture's link) is not text, so such a paste attaches
//   its picture. Rich text (HTML) with a lone link not marked as a URL (a spreadsheet cell) is text.
// - The words beside the files (items with text and no file) paste at the caret.
// - A file the data side cannot take is refused before it uploads, with the notice the Swift box
//   gave: an empty file (or a folder, which the web reads as an empty file) says it is empty, and one
//   past the upload limit says it can't be attached.
import { refusal } from "../../home-channels/attachmentService";

/** The parts of a DataTransfer the rules read (a real one, or a value in tests). */
export interface TransferLike {
  readonly files: ArrayLike<File>;
  readonly types: readonly string[];
  getData(type: string): string;
}

const LINK_SCHEMES = new Set(["http:", "https:", "file:", "data:", "blob:"]);

/** Whether the transfer carries text the person meant to paste (`HomeAttachmentIntake.hasText`). */
export function hasText(transfer: TransferLike): boolean {
  if (!transfer.types.includes("text/plain")) return false;
  const rich = transfer.types.includes("text/html") || transfer.types.includes("text/rtf");
  if (rich && !transfer.types.includes("text/uri-list")) return true;
  const text = transfer.getData("text/plain").trim();
  if (!text) return false;
  if (/\s/.test(text)) return true;
  try {
    return !LINK_SCHEMES.has(new URL(text).protocol);
  } catch {
    return true;
  }
}

/** The files a paste or drop attaches, in order. */
export function transferFiles(transfer: TransferLike): File[] {
  return Array.from(transfer.files);
}

/** The words a paste with files carries beside them, or undefined: a text that only names the
 * files (their names or paths) or a lone link is not words. */
export function textBeside(transfer: TransferLike): string | undefined {
  const files = transferFiles(transfer);
  if (files.length === 0 || !hasText(transfer)) return undefined;
  const text = transfer.getData("text/plain").trim();
  const names = text.split(/\r?\n/).map((line) => line.trim());
  const onlyNames = names.every((line) => files.some((file) => line === file.name || line.endsWith(`/${file.name}`)));
  return onlyNames ? undefined : text;
}

export type IntakeProblem = { kind: "empty" | "refused"; name: string };

/** Why a file may not attach (`HomeComposerCheck.problem`), or undefined. */
export function intakeProblem(file: File, pastedName: string): IntakeProblem | undefined {
  const name = file.name || pastedName;
  if (file.size === 0) return { kind: "empty", name };
  if (refusal(file)) return { kind: "refused", name };
  return undefined;
}
