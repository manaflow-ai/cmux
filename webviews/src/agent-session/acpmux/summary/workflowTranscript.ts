import type { AcpmuxRow } from "../model";
import { childRows, type ChildEntry } from "../subagents/childRows";
import type { WorkflowDetailRequest } from "./foldWorkflows";

/// Transport identity inside the existing subagent pane reveal. UI keys stay node/index keys.
const PREFIX = "workflow:";
export const workflowPaneId = (request: WorkflowDetailRequest) =>
  PREFIX + JSON.stringify([request.sessionId, request.runId, request.agentId]);
export function workflowPaneRequest(id: string | undefined): WorkflowDetailRequest | undefined {
  if (!id?.startsWith(PREFIX)) return undefined;
  try {
    const parts: unknown = JSON.parse(id.slice(PREFIX.length));
    if (!Array.isArray(parts) || parts.length !== 3 || parts.some((part) => typeof part !== "string" || !part))
      return undefined;
    const [sessionId, runId, agentId] = parts as [string, string, string];
    return { sessionId, runId, agentId };
  } catch {
    return undefined;
  }
}

export type TranscriptRead = (request: WorkflowDetailRequest & { before?: number; after?: number }) => Promise<unknown>;
type Page = {
  start: number;
  end: number;
  lines: number;
  updates: unknown[];
  truncated: boolean;
  offset: number;
};
function pageOf(value: unknown): Page {
  const page = value as Page | null;
  if (
    !page ||
    !Array.isArray(page.updates) ||
    ![page.start, page.end, page.lines].every((n) => Number.isSafeInteger(n) && n >= 0) ||
    page.start > page.end ||
    page.end > page.lines
  )
    throw new Error("Invalid transcript page");
  return { ...page, offset: 0 };
}

/// One opened transcript only. Refresh replaces the last page (including an incomplete last
/// JSONL line) and follows forward cursors if progress outran a page. Older history is pulled
/// by the transcript's existing Load older control. No timer or parent-token subscription.
export class WorkflowTranscript {
  private pages: Page[] = [];
  private stopped = false;
  private pending = false;
  private flight?: Promise<void>;
  private version = 0;
  rows: AcpmuxRow[] = [];
  loading = false;
  failed = false;
  get canLoadOlder() {
    return (this.pages[0]?.start ?? 0) > 0;
  }
  get truncated() {
    return this.pages.some((page) => page.truncated);
  }
  constructor(
    readonly request: WorkflowDetailRequest,
    private readonly read: TranscriptRead,
    private readonly changed: () => void,
  ) {}
  dispose() {
    this.stopped = true;
    this.pending = false;
  }
  refresh(): Promise<void> {
    if (this.stopped) return Promise.resolve();
    if (this.flight) {
      this.pending = true;
      return this.flight;
    }
    return this.run(false);
  }
  loadOlder(): Promise<void> {
    if (this.stopped || !this.canLoadOlder) return Promise.resolve();
    if (this.flight) return this.flight;
    return this.run(true);
  }
  private run(older: boolean): Promise<void> {
    this.loading = true;
    this.changed();
    this.flight = this.pull(older)
      .then(
        () => {
          this.failed = false;
        },
        () => {
          this.failed = true;
        },
      )
      .finally(() => {
        this.flight = undefined;
        if (this.stopped) return;
        this.loading = false;
        this.changed();
        if (this.pending) {
          this.pending = false;
          void this.refresh();
        }
      });
    return this.flight;
  }
  private async pull(older: boolean) {
    const last = this.pages.at(-1);
    const cursor = older ? { before: this.pages[0]!.start } : last ? { after: last.start } : {};
    let page = pageOf(await this.read({ ...this.request, ...cursor }));
    if (this.stopped) return;
    if (older) {
      if (page.end !== this.pages[0]!.start || page.start >= page.end) throw new Error("Transcript cursor changed");
      page.offset = this.pages[0]!.offset - page.updates.length;
      this.pages = [page, ...this.pages];
    } else {
      // A truncated/replaced file changes cursor origin: discard old pages, never join two files.
      const reset = last && (page.start !== last.start || page.lines < last.lines || page.truncated);
      if (reset) page = pageOf(await this.read(this.request));
      if (this.stopped) return;
      const next = reset || !last ? [] : this.pages.slice(0, -1);
      page.offset = reset || !last ? 0 : last.offset;
      next.push(page);
      const through = page.lines;
      while (page.end < through) {
        const previous = page;
        page = pageOf(await this.read({ ...this.request, after: previous.end }));
        if (this.stopped) return;
        if (page.start !== previous.end || page.end <= previous.end)
          throw new Error("Transcript cursor did not advance");
        page.offset = previous.offset + previous.updates.length;
        next.push(page);
      }
      this.pages = next;
    }
    this.version += 1;
    const entries: ChildEntry[] = [];
    for (const chunk of this.pages)
      chunk.updates.forEach((update, index) => entries.push({ event: { seq: chunk.offset + index, at: 0 }, update }));
    this.rows = childRows(workflowPaneId(this.request), entries, new Map(), this.version).map((row) => ({
      ...row,
      version: this.version,
    }));
  }
}
