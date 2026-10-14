// A thread as an object: title, status (open or resolved) and owner. The conversation owner does
// not keep these yet; until it does, `threadObject` derives the title from the root's first line
// and the owner from the root's author, and the status lives in this page's ThreadStatusBook.
// Every view reads threads only through `threadObject` and writes status only through
// `ThreadStatusBook.set`, so wiring the owner's fields is one change here.
import { messageText } from "./model";
import type { HomeMessage } from "./types";

export type ThreadStatus = "open" | "resolved";

export interface ThreadObject {
  root: string;
  title: string;
  status: ThreadStatus;
  /** The participant who owns the thread (today: the root's author). */
  owner: string;
}

/** The longest title the derivation keeps (the row truncates by width before this). */
const TITLE_MAX = 120;

/** The root's first non-empty line without Markdown marks. */
export function deriveTitle(root: HomeMessage | undefined): string {
  if (!root) return "";
  const line =
    messageText(root)
      .split("\n")
      .map((part) => part.trim())
      .find((part) => part.length > 0) ?? "";
  const plain = line
    .replace(/^#+\s+|^[-*>]\s+|^\d+\.\s+/, "")
    .replace(/[*_`~]/g, "")
    .replace(/[:;,]\s*$/, "");
  return plain.length > TITLE_MAX ? `${plain.slice(0, TITLE_MAX - 1)}…` : plain;
}

export function threadObject(root: HomeMessage, status: ThreadStatus): ThreadObject {
  return { root: root.id, title: deriveTitle(root), status, owner: root.author };
}

/** The page-local status of threads, by root id (placeholder for the owner's field). */
export class ThreadStatusBook {
  private readonly resolved = new Set<string>();
  private readonly listeners = new Set<() => void>();
  private version = 0;

  status(root: string): ThreadStatus {
    return this.resolved.has(root) ? "resolved" : "open";
  }

  set(root: string, status: ThreadStatus): void {
    if (status === this.status(root)) return;
    if (status === "resolved") this.resolved.add(root);
    else this.resolved.delete(root);
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  toggle(root: string): void {
    this.set(root, this.status(root) === "open" ? "resolved" : "open");
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;
}
