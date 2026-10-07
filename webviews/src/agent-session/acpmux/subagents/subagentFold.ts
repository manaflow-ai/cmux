import type { AcpmuxRow } from "../model";

export const SUBAGENTS = "subagents";

export type Subagent = {
  id: string;
  parent: string | null;
  name: string;
  task?: string;
  state: string;
  startedAt: number;
  endedAt?: number;
  action?: string;
};

export class SubagentFold {
  reduce(_event: { seq: number; at: number; msg?: any }, _update: any): boolean {
    return false;
  }
  closeBatch(): void {}
  takeRows(): AcpmuxRow[] {
    return [];
  }
  all(): Subagent[] {
    return [];
  }
}
