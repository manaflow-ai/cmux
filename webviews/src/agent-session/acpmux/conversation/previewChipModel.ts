// The pages the chat's running background commands serve (PreviewChip.tsx), by the call that
// started each, and how one opens.
import { createContext } from "react";
import type { ProcessPreview, SessionInfoProcess } from "../session-info/processes";

export type PreviewChips = {
  /// Each running process's page, by the tool call that started it.
  byTool: ReadonlyMap<string, ProcessPreview>;
  /// The newest running process's page: the running turn's line names it.
  latest?: ProcessPreview;
  open(preview: ProcessPreview): void;
};

export const PreviewChipsContext = createContext<PreviewChips | undefined>(undefined);

const NONE: ReadonlyMap<string, ProcessPreview> = new Map();

/// The running processes' pages, newest last; one pass over the chat's processes.
export function previewsOf(processes: readonly SessionInfoProcess[]): {
  byTool: ReadonlyMap<string, ProcessPreview>;
  latest?: ProcessPreview;
} {
  let byTool: Map<string, ProcessPreview> | undefined;
  let latest: { preview: ProcessPreview; startedAt: number } | undefined;
  for (const process of processes) {
    if (process.state !== "running" || !process.preview) continue;
    if (process.toolCallId) (byTool ??= new Map()).set(process.toolCallId, process.preview);
    if (!latest || process.startedAt >= latest.startedAt)
      latest = { preview: process.preview, startedAt: process.startedAt };
  }
  return { byTool: byTool ?? NONE, ...(latest ? { latest: latest.preview } : {}) };
}

/// What the chip reads: `localhost:5173`, with the path when it is not the root (`localhost:3000/admin`).
export function previewAddress(url: string): string {
  try {
    const parsed = new URL(url);
    const path = parsed.pathname === "/" ? "" : parsed.pathname.replace(/\/$/, "");
    return `${parsed.host}${path}`;
  } catch {
    return url;
  }
}
