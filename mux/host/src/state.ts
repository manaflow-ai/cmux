import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";

/**
 * The brain host's own durable state ($MUX_HOME/state/host.json). The host is
 * its only writer. Everything here is a cache of facts the owners keep (the
 * conversation owner's read cursors and op ledger, acpmux's event log), so
 * losing it only costs a replay: every effect it guards is idempotent.
 */
export interface HostStateData {
  /** The default "mux" conversation id (from conversation-create). */
  defaultConversation?: string;
  /** The acpmux session id of the mux and how far its event log is folded. */
  muxSessionId?: string;
  acpmuxSeq: number;
  /** promptId -> the conversation (and message seq) its turn answers. */
  prompts: Record<string, { conversation: string; seq?: number }>;
  /** Prompt ids the mux already received (acpmux recorded a user_message), newest last. */
  delivered: string[];
  /** Child agents: acpmux session id -> its work-part message. */
  children: Record<string, { conversation: string; messageId: string; name: string; status: string }>;
}

const MAX_DELIVERED = 5_000;

export class HostState {
  data: HostStateData;
  private readonly deliveredSet: Set<string>;

  constructor(private readonly path: string) {
    const empty: HostStateData = { acpmuxSeq: 0, prompts: {}, delivered: [], children: {} };
    let loaded: Partial<HostStateData> = {};
    if (existsSync(path)) {
      try {
        loaded = JSON.parse(readFileSync(path, "utf8")) as Partial<HostStateData>;
      } catch {
        loaded = {};
      }
    }
    this.data = { ...empty, ...loaded };
    this.deliveredSet = new Set(this.data.delivered);
  }

  isDelivered(promptId: string): boolean {
    return this.deliveredSet.has(promptId);
  }

  markDelivered(promptId: string): void {
    if (this.deliveredSet.has(promptId)) return;
    this.deliveredSet.add(promptId);
    this.data.delivered.push(promptId);
    while (this.data.delivered.length > MAX_DELIVERED) this.deliveredSet.delete(this.data.delivered.shift()!);
  }

  save(): void {
    const tmp = `${this.path}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(this.data)}\n`);
    renameSync(tmp, this.path);
  }
}
