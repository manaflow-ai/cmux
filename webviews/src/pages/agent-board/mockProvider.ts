// l10n-allow-file: mock host for the browser dev loop (`/agent-board/?mock`) and the gallery.
// Answers the Agent Board ops from sample ledgers; images are drawn stand-ins of the right theme.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { mockLedgers, type MockBoardKind } from "./fixtures";
import { AgentBoardOps } from "./types";

export class MockAgentBoardProvider implements PageClient {
  private listeners = new Set<() => void>();

  constructor(
    private kind: MockBoardKind = "live",
    private readonly now: () => number = () => Date.now(),
    private readonly failure?: { code: string; message: string },
  ) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    if (this.failure) throw pageError(this.failure.code, this.failure.message, true);
    const p = (params ?? {}) as { on?: boolean; path?: string };
    switch (op) {
      case AgentBoardOps.state:
        return {
          enabled: this.kind !== "off",
          folder: "~/.cmux/agent-board",
          ledgers: mockLedgers(this.kind, this.now()),
        } as R;
      case AgentBoardOps.setEnabled:
        this.kind = p.on ? "empty" : "off";
        for (const listener of this.listeners) listener();
        return { enabled: Boolean(p.on) } as R;
      case AgentBoardOps.evidence:
        return { dataURL: standIn(p.path ?? "") } as R;
      case AgentBoardOps.open:
        return { opened: true } as R;
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== AgentBoardOps.changes) throw pageError("cmux.op.unknown", stream);
    const listener = () => onEvent({} as E, 0);
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

/** A drawn screenshot: dark for a path that says dark, light otherwise. */
function standIn(path: string): string {
  const dark = /dark/.test(path);
  const [bg, bar, ink, accent] = dark
    ? ["#1d1d1f", "#2c2c2e", "#8e8e93", "#0a84ff"]
    : ["#f5f5f7", "#e5e5ea", "#aeaeb2", "#0a84ff"];
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400"><rect width="640" height="400" fill="${bg}"/><rect width="640" height="56" fill="${bar}"/><rect x="48" y="120" width="360" height="28" rx="6" fill="${ink}"/><rect x="48" y="176" width="240" height="28" rx="6" fill="${accent}"/><rect x="48" y="232" width="420" height="20" rx="6" fill="${ink}" opacity=".5"/></svg>`;
  return `data:image/svg+xml;base64,${btoa(svg)}`;
}
