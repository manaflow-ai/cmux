import postgres from "postgres";
import { WorkspaceSnapshotSchema, type WorkspaceSnapshot } from "../contracts/workspaces";
import { OperationError } from "../errors";

export interface WorkspaceState {
  generation: string;
  revision: number;
  snapshot: WorkspaceSnapshot;
}

export interface WorkspaceProductStore {
  get(teamId: string, vmId: string): Promise<WorkspaceState | null>;
  list(teamId: string): Promise<ReadonlyArray<{ vmId: string; generation: string; revision: number }>>;
  put(input: { teamId: string; vmId: string; generation: string; revision: number; snapshot: WorkspaceSnapshot }): Promise<{ state: WorkspaceState; changed: boolean }>;
}

/** Product state lives in cmux-prod through the environment's Hyperdrive binding. */
export class PostgresWorkspaceProductStore implements WorkspaceProductStore {
  constructor(private readonly connectionString: string) {}

  async get(teamId: string, vmId: string) {
    const sql = postgres(this.connectionString, { max: 1, prepare: true, fetch_types: false });
    try {
      const rows = await sql<{ generation: string; revision: number; snapshot: unknown }[]>`
        SELECT generation, revision, snapshot
        FROM cmux_workspace_snapshots
        WHERE team_id = ${teamId} AND vm_id = ${vmId}`;
      const row = rows[0];
      return row ? { generation: row.generation, revision: Number(row.revision), snapshot: WorkspaceSnapshotSchema.parse(row.snapshot) } : null;
    } catch { throw new OperationError("storage_unavailable", 503, true, 2000); }
    finally { await sql.end({ timeout: 1 }); }
  }

  async list(teamId: string) {
    const sql = postgres(this.connectionString, { max: 1, prepare: true, fetch_types: false });
    try {
      const rows = await sql<{ vm_id: string; generation: string; revision: number }[]>`
        SELECT vm_id, generation, revision
        FROM cmux_workspace_snapshots
        WHERE team_id = ${teamId}
        ORDER BY updated_at DESC
        LIMIT 4096`;
      return rows.map(row => ({ vmId: row.vm_id, generation: row.generation, revision: Number(row.revision) }));
    } catch { throw new OperationError("storage_unavailable", 503, true, 2000); }
    finally { await sql.end({ timeout: 1 }); }
  }

  async put(input: { teamId: string; vmId: string; generation: string; revision: number; snapshot: WorkspaceSnapshot }) {
    const sql = postgres(this.connectionString, { max: 1, prepare: true, fetch_types: false });
    try {
      const state = await sql.begin(async tx => {
        const current = await tx<{ generation: string; revision: number; snapshot: unknown }[]>`
          SELECT generation, revision, snapshot FROM cmux_workspace_snapshots
          WHERE team_id = ${input.teamId} AND vm_id = ${input.vmId} FOR UPDATE`;
        const row = current[0];
        if (row && row.generation === input.generation && input.revision <= Number(row.revision)) {
          return {
            state: { generation: row.generation, revision: Number(row.revision), snapshot: WorkspaceSnapshotSchema.parse(row.snapshot) },
            changed: false,
          };
        }
        if (row && row.generation === input.generation && input.revision !== Number(row.revision) + 1) {
          throw new OperationError("resync_required", 409, true);
        }
        await tx`
          INSERT INTO cmux_workspace_events (team_id, vm_id, generation, revision, snapshot)
          VALUES (${input.teamId}, ${input.vmId}, ${input.generation}, ${input.revision}, ${sql.json(input.snapshot)})
          ON CONFLICT (team_id, vm_id, generation, revision) DO NOTHING`;
        await tx`
          INSERT INTO cmux_workspace_snapshots (team_id, vm_id, generation, revision, snapshot)
          VALUES (${input.teamId}, ${input.vmId}, ${input.generation}, ${input.revision}, ${sql.json(input.snapshot)})
          ON CONFLICT (team_id, vm_id) DO UPDATE SET generation = EXCLUDED.generation,
            revision = EXCLUDED.revision, snapshot = EXCLUDED.snapshot, updated_at = now()`;
        return { state: input, changed: true };
      });
      return state.changed
        ? {
          ...state,
          state: {
            generation: input.generation,
            revision: input.revision,
            snapshot: input.snapshot,
          },
        }
        : state;
    } catch (error) {
      if (error instanceof OperationError) throw error;
      throw new OperationError("storage_unavailable", 503, true, 2000);
    } finally { await sql.end({ timeout: 1 }); }
  }
}
