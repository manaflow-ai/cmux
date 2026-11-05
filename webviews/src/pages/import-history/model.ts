import type { PageClient } from "../shared/pageClient";

export type Origin = "grok-bot" | "muse" | "dots" | "instinct";
export type RowID =
  | "claude-code"
  | "codex"
  | "codex-sessions"
  | "claude-memory"
  | "chatgpt"
  | "claude"
  | Origin
  | "dot"
  | `detected-${number}`;
export type Phase = "idle" | "detecting" | "ready" | "importing" | "done" | "error";
export type RowPhase = "idle" | "planning" | "writing" | "done" | "error";
export interface ImportReport {
  plan: { total: number; new: number; duplicate: number; secrets: number };
  est_cost_usd: number;
  written?: number;
}
export interface HistoryRow {
  id: RowID;
  kind: "local" | "zip" | "text";
  selected: boolean;
  expanded?: boolean;
  source?: string;
  name?: string;
  title?: string;
  icon?: string;
  detected?: boolean;
  text?: string;
  phase: RowPhase;
  report?: ImportReport;
  error?: string;
}
export interface HistorySnapshot {
  phase: Phase;
  rows: HistoryRow[];
  batch?: string;
  canUndo: boolean;
  undoing: boolean;
  picking?: RowID;
  copied?: RowID;
  error?: string;
  /** A line about another tool's import from the host (Import from Conductor's), shown under the sources. */
  notice?: string;
}
export const OPS = {
  detect: "cmux.importHistory.detect",
  pickZip: "cmux.importHistory.pickZip",
  begin: "cmux.importHistory.begin",
  prepareText: "cmux.importHistory.prepareText",
  dryRun: "cmux.importHistory.dryRun",
  write: "cmux.importHistory.write",
  undo: "cmux.importHistory.undo",
  finish: "cmux.importHistory.finish",
  copy: "cmux.app.clipboard.write",
} as const;
export const ORIGINS: Origin[] = ["grok-bot", "muse", "dots", "instinct"];
export const initialRows = (): HistoryRow[] => [
  ...(["claude-code", "codex", "codex-sessions", "claude-memory"] as const).map((id) => ({
    id,
    kind: "local" as const,
    selected: false,
    phase: "idle" as const,
  })),
  ...(["chatgpt", "claude"] as const).map((id) => ({
    id,
    kind: "zip" as const,
    selected: false,
    phase: "idle" as const,
  })),
  ...ORIGINS.map((id) => ({
    id,
    kind: "text" as const,
    selected: false,
    phase: "idle" as const,
    text: "",
  })),
];
export function canImport(snapshot: HistorySnapshot): boolean {
  return (
    !["detecting", "importing"].includes(snapshot.phase) &&
    !snapshot.undoing &&
    !snapshot.picking &&
    snapshot.rows.some((row) => row.selected && (row.kind === "text" ? row.text?.trim() : row.source))
  );
}
const message = (error: unknown): string => (error instanceof Error ? error.message : String(error));

/** One owner for detection, explicit picks and the complete batch. Export discovery is explicit. */
export class ImportHistoryStore {
  private snapshot: HistorySnapshot;
  private readonly listeners = new Set<() => void>();
  private detecting = false;
  private stopped = false;
  constructor(
    private readonly client: Pick<PageClient, "call"> | null,
    initial?: HistorySnapshot,
  ) {
    this.snapshot = initial ?? {
      phase: "idle",
      rows: initialRows(),
      canUndo: false,
      undoing: false,
    };
  }
  getSnapshot = (): HistorySnapshot => this.snapshot;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  private set(patch: Partial<HistorySnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
  private row(id: RowID, patch: Partial<HistoryRow>): void {
    this.set({
      rows: this.snapshot.rows.map((row) => (row.id === id ? { ...row, ...patch } : row)),
    });
  }
  private get busy(): boolean {
    return this.snapshot.phase === "importing" || this.snapshot.undoing;
  }
  async start(): Promise<void> {
    if (this.snapshot.phase !== "idle") return;
    await this.detect(false);
  }
  async findExports(): Promise<void> {
    await this.detect(true);
  }
  private async detect(exports: boolean): Promise<void> {
    if (this.detecting || this.busy) return;
    this.detecting = true;
    this.set({ phase: "detecting" });
    try {
      if (!this.client) throw new Error("cmux.importHistory.unavailable");
      const result = await this.client.call<{
        sources: { source: string; kind?: string; title?: string; path?: string }[];
        notice?: string | null;
      }>(OPS.detect, exports ? { exports: true } : {});
      const detected = result.sources ?? [];
      this.set({
        phase: "ready",
        notice: result.notice ?? undefined,
        rows: this.snapshot.rows
          .filter((row) => !row.id.startsWith("detected-"))
          .map((row) => {
            if (row.kind === "zip" && row.source && !row.detected) return row;
            const found = detected.find((source) => source.source === row.id || source.kind === row.id);
            const exportKind =
              row.id === "chatgpt" ? "chatgpt-export" : row.id === "claude" ? "claude-ai-export" : undefined;
            const exportFound = exportKind && detected.find((source) => source.kind === exportKind);
            const match = found ?? exportFound;
            return match
              ? {
                  ...row,
                  selected: true,
                  expanded: row.kind === "text" ? true : row.expanded,
                  source: match.source,
                  detected: true,
                  name: match.title ?? match.path,
                }
              : row.detected
                ? { ...row, selected: false, detected: false, source: undefined, name: undefined }
                : row;
          })
          .concat(
            detected
              .filter(
                (source) =>
                  source.source.startsWith("zip:") &&
                  !["chatgpt-export", "claude-ai-export"].includes(source.kind ?? ""),
              )
              .map((source, index) => ({
                id: `detected-${index}` as const,
                kind: "zip" as const,
                selected: true,
                source: source.source,
                name: source.title ?? source.path,
                title: source.kind === "dots-export" ? "Dot export (.zip)" : "Saved export (.zip)",
                icon: source.kind === "dots-export" ? "D" : "↗",
                detected: true,
                phase: "idle" as const,
              })),
          ),
      });
    } catch (error) {
      this.set({ phase: "error", error: message(error) });
    } finally {
      this.detecting = false;
    }
  }
  async retryDetection(): Promise<void> {
    if (this.detecting || this.busy) return;
    this.set({ phase: "idle", error: undefined });
    await this.start();
  }
  select(id: RowID, selected: boolean): void {
    if (this.busy) return;
    this.row(id, { selected, report: undefined, phase: "idle", error: undefined });
    this.set({ phase: this.detecting ? "detecting" : "ready", error: undefined });
  }
  expand(id: RowID): void {
    if (!this.busy) this.row(id, { expanded: !this.snapshot.rows.find((row) => row.id === id)?.expanded });
  }
  paste(id: Origin, text: string): void {
    if (this.busy) return;
    this.row(id, {
      text,
      selected: Boolean(text.trim()),
      report: undefined,
      phase: "idle",
      error: undefined,
      source: undefined,
    });
    this.set({ phase: this.detecting ? "detecting" : "ready", error: undefined });
  }
  async copy(id: Origin, text: string): Promise<void> {
    try {
      if (!this.client) throw new Error("cmux.importHistory.unavailable");
      await this.client.call(OPS.copy, { text });
      this.set({ copied: id, error: undefined });
    } catch (error) {
      this.set({ error: message(error) });
    }
  }
  async pickZip(id: RowID): Promise<void> {
    if (!this.client || this.busy || this.snapshot.picking) return;
    this.set({ picking: id, error: undefined });
    try {
      const result = await this.client.call<{ source: string; name: string } | null>(OPS.pickZip, {
        kind: id.startsWith("detected-") ? "dot" : id,
      });
      if (!result) return;
      if (id === "dot" && !this.snapshot.rows.some((row) => row.id === "dot")) {
        this.set({
          rows: [...this.snapshot.rows, { id, kind: "zip", selected: true, phase: "idle", ...result }],
        });
      } else
        this.row(id, {
          ...result,
          detected: false,
          selected: true,
          report: undefined,
          phase: "idle",
          error: undefined,
        });
      this.set({ phase: this.detecting ? "detecting" : "ready", error: undefined });
    } catch (error) {
      this.set({ error: message(error) });
    } finally {
      this.set({ picking: undefined });
    }
  }
  async run(): Promise<void> {
    if (!this.client || this.detecting || !canImport(this.snapshot)) return;
    this.stopped = false;
    const client = this.client;
    const selected = this.snapshot.rows.filter(
      (row) => row.selected && (row.kind === "text" ? row.text?.trim() : row.source),
    );
    // A failed or partly written attempt retains its native grant, backup and Undo until undone.
    const batch = this.snapshot.batch ?? crypto.randomUUID();
    this.set({ phase: "importing", batch, error: undefined });
    // The first call spends the click's native gesture; subsequent calls are scoped to this batch.
    try {
      await client.call(OPS.begin, { batch });
    } catch (error) {
      this.set({ phase: "error", error: message(error) });
      return;
    }
    if (this.stopped) return;
    const planned: { row: HistoryRow; source: string; origin?: Origin }[] = [];
    for (const row of selected) {
      if (this.stopped) return;
      this.row(row.id, { phase: "planning", error: undefined });
      try {
        const origin = row.kind === "text" ? (row.id as Origin) : undefined;
        const source = origin
          ? (
              await client.call<{ source: string }>(OPS.prepareText, {
                summaryOrigin: origin,
                text: row.text ?? "",
              })
            ).source
          : row.source;
        if (this.stopped) return;
        if (!source) throw new Error("cmux.importHistory.missing_source");
        const report = await client.call<ImportReport>(OPS.dryRun, {
          source,
          batch,
          ...(origin ? { summaryOrigin: origin } : {}),
        });
        if (this.stopped) return;
        if (
          !Number.isFinite(report.plan.new) ||
          report.plan.new < 0 ||
          !Number.isFinite(report.est_cost_usd) ||
          report.est_cost_usd > 20
        )
          throw new Error("cmux.importHistory.invalid_plan");
        this.row(row.id, { report, phase: "idle" });
        planned.push({ row, source, origin });
      } catch (error) {
        this.row(row.id, { phase: "error", error: message(error) });
      }
    }
    // Every inline plan is visible before the first write; one batch gives the whole screen one Undo.
    for (const { row, source, origin } of planned) {
      if (this.stopped) return;
      const report = this.snapshot.rows.find((current) => current.id === row.id)?.report;
      if (!report?.plan.new) {
        this.row(row.id, { phase: "done" });
        continue;
      }
      this.row(row.id, { phase: "writing" });
      try {
        const result = await client.call<ImportReport>(OPS.write, {
          source,
          batch,
          ...(origin ? { summaryOrigin: origin } : {}),
        });
        if (this.stopped) return;
        this.row(row.id, { phase: "done", report: result });
        if ((result.written ?? 0) > 0) this.set({ canUndo: true });
      } catch (error) {
        this.row(row.id, { phase: "error", error: message(error) });
      }
    }
    this.set({ phase: this.snapshot.rows.some((row) => row.phase === "error") ? "error" : "done" });
  }
  async undo(): Promise<void> {
    if (!this.client || this.busy || !this.snapshot.canUndo) return;
    this.set({ undoing: true, error: undefined });
    try {
      await this.client.call(OPS.undo, { batch: this.snapshot.batch });
      this.set({
        phase: "ready",
        canUndo: false,
        batch: undefined,
        rows: this.snapshot.rows.map((row) => ({
          ...row,
          report: undefined,
          phase: "idle",
          error: undefined,
        })),
      });
    } catch (error) {
      this.set({ error: message(error) });
    } finally {
      this.set({ undoing: false });
    }
  }
  async finish(completed: boolean): Promise<void> {
    // Skip stays available during work. Let an in-flight process settle; start no further source.
    this.stopped = true;
    try {
      await this.client?.call(OPS.finish, { completed });
    } catch (error) {
      this.set({ phase: "error", error: message(error) });
    }
  }
}
