import {
  CHECKPOINT_OPS,
  checkpointList,
  checkpointRecord,
  mutationEnvelope,
  CheckpointRpcError,
  type Checkpoint,
  type CheckpointCatalog,
  type CheckpointList,
  type CheckpointTarget,
  type MutationEnvelope,
} from "./protocol";

export type { CheckpointTarget } from "./protocol";
export type Request = (method: string, params: Record<string, unknown>) => Promise<unknown>;
export interface CheckpointPersistence { get(key: string): Promise<unknown>; set(key: string, value: unknown): Promise<void>; delete(key: string): Promise<void>; }
export type CheckpointClientState = {
  target?: CheckpointTarget; supported: boolean; list?: CheckpointList; record?: Checkpoint;
  busy?: "listing" | "creating" | "pinning" | "unpinning"; error?: CheckpointRpcError;
};
export type CreateInput = { expected_repository_id?: string; expected_worktree_id?: string; include_untracked?: string[] | "eligible"; exclude_paths?: string[]; reason?: "manual" | "handoff"; limits?: { max_bytes?: number; max_files?: number } };
export type PinInput = { checkpoint_id: string; pin_id: string; reason: string };
export type UnpinInput = { checkpoint_id: string; pin_id: string };

export class CheckpointClient {
  state: CheckpointClientState = { supported: false };
  constructor(_request: Request, _persistence: CheckpointPersistence, _key: () => string = () => crypto.randomUUID()) {}
  select(target?: CheckpointTarget): void { this.state = { supported: this.state.supported, target }; }
  setCatalog(_catalog: CheckpointCatalog | unknown, _expectedSha?: string): void {}
  setOnline(_online: boolean): void {}
  async list(_params: { include_candidates?: boolean; cursor?: string; limit?: number } = {}): Promise<CheckpointList> { throw new Error("not implemented"); }
  async get(_params: { checkpoint_id?: string; idempotency_key?: string }): Promise<Checkpoint> { throw new Error("not implemented"); }
  async create(_input: CreateInput): Promise<MutationEnvelope<Checkpoint>> { throw new Error("not implemented"); }
  async pin(_input: PinInput): Promise<MutationEnvelope<Checkpoint>> { throw new Error("not implemented"); }
  async unpin(_input: UnpinInput): Promise<MutationEnvelope<Checkpoint>> { throw new Error("not implemented"); }
}
