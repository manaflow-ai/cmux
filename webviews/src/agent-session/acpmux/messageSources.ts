import type { AcpmuxRow } from "./model";
import { safeHref } from "./replyHref";

/** Successful reads recorded by acpmux, never URLs extracted from the answer. */
export interface MessageSource {
  kind: "file" | "web" | "rfd" | "wiki";
  uri: string;
  title: string;
  toolCallId: string;
  revision?: string;
  backlink?: string;
}

/** Validate the daemon event at the transport boundary; source inference lives in Rust. */
export function readMessageSources(value: unknown): MessageSource[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 64).flatMap((item): MessageSource[] => {
    if (!item || typeof item !== "object") return [];
    const { kind, uri, title, toolCallId, revision, backlink } = item;
    if (
      !["file", "web", "rfd", "wiki"].includes(kind) ||
      typeof uri !== "string" ||
      typeof title !== "string" ||
      typeof toolCallId !== "string" ||
      !toolCallId ||
      !uri
    )
      return [];
    if (kind === "web" && !safeHref(uri)) return [];
    return [
      {
        kind,
        uri,
        title,
        toolCallId,
        ...(typeof revision === "string" && { revision }),
        ...(typeof backlink === "string" && safeHref(backlink) && { backlink: safeHref(backlink) }),
      },
    ];
  });
}

/** Exact reply identity prevents late events and replay pages marking another turn. */
export function markMessageSources(row: AcpmuxRow | undefined, msg: Record<string, unknown>): AcpmuxRow | undefined {
  if (
    !row ||
    row.kind !== "assistant" ||
    typeof msg.turnId !== "string" ||
    typeof msg.replyId !== "string" ||
    row.id !== `assistant-${msg.replyId}` ||
    !msg.replyId.startsWith(`${msg.turnId}.`)
  )
    return undefined;
  const sources = readMessageSources(msg.sources);
  return sources.length ? { ...row, version: row.version + 1, sources } : undefined;
}

/** File URIs identify a document; the host rechecks the decoded path before opening. */
export function sourceFilePath(uri: string): string | undefined {
  try {
    const url = new URL(uri);
    if (url.protocol !== "file:" || url.hostname || url.search || url.hash) return undefined;
    const path = decodeURIComponent(url.pathname);
    return path.startsWith("/") && !/[\u0000-\u001f\u007f]/.test(path) ? path : undefined;
  } catch {
    return undefined;
  }
}
