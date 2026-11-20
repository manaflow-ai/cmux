// l10n-allow-file: public-safe gallery and browser development fixtures.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { OPS, type ImportReport } from "./model";

export class MockImportHistoryProvider implements PageClient {
  private readonly imported = new Set<string>();
  constructor(private readonly empty = false) {}
  async call<R>(op: string, params: unknown): Promise<R> {
    const input = (params ?? {}) as { source?: string; summaryOrigin?: string; kind?: string };
    switch (op) {
      case OPS.detect:
        return {
          sources: this.empty
            ? []
            : [
                ...["claude-code", "codex-sessions", "codex", "claude-memory"].map((source) => ({
                  source,
                  kind: source,
                  items: 12,
                  bytes: 4000,
                })),
                {
                  source: "zip:/sample/chatgpt-export.zip",
                  kind: "chatgpt-export",
                  path: "/Users/example/Downloads/chatgpt-export.zip",
                  items: 1,
                  bytes: 24000,
                },
                {
                  source: "zip:/sample/claude-export.zip",
                  kind: "claude-ai-export",
                  path: "/Users/example/Desktop/claude-export.zip",
                  items: 1,
                  bytes: 18000,
                },
              ],
        } as R;
      case OPS.pickZip:
        return {
          source: `zip:/sample/${input.kind}-export.zip`,
          name: `${input.kind}-export.zip`,
        } as R;
      case OPS.prepareText:
        return { source: `text:/sample/${input.summaryOrigin}.txt` } as R;
      case OPS.dryRun:
        return this.report(input.source ?? "") as R;
      case OPS.write: {
        const report = this.report(input.source ?? "");
        this.imported.add(input.source ?? "");
        return { ...report, written: report.plan.new } as R;
      }
      case OPS.undo:
        this.imported.clear();
        return {} as R;
      case OPS.begin:
      case OPS.finish:
      case OPS.copy:
        return {} as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }
  private report(source: string): ImportReport {
    return {
      plan: {
        total: 12,
        new: this.imported.has(source) ? 0 : 12,
        duplicate: this.imported.has(source) ? 12 : 0,
        secrets: 0,
      },
      est_cost_usd: 0.02,
    };
  }
  async subscribe(): Promise<() => void> {
    return () => {};
  }
  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}
