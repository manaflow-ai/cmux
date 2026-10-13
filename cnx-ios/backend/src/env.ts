import type { TeamHub } from "./team-hub.ts"

export interface Env {
  readonly ENVIRONMENT: string
  readonly API_VERSION: string
  /**
   * JSON array of the Stack projects whose users this Worker accepts (see `StackProject` in auth.ts).
   * The first entry is the primary project: rows written before multi-project support belong to it, and
   * STACK_SECRET_SERVER_KEY (when set) is its server key.
   */
  readonly STACK_PROJECTS: string
  readonly TEAM_HUB: DurableObjectNamespace<TeamHub>
  /** Absent in tests: the memory store is used instead. */
  readonly HYPERDRIVE?: Hyperdrive
  /** Optional: the primary project's server key. Membership and invites then use the Stack server API for that project's users. */
  readonly STACK_SECRET_SERVER_KEY?: string
  readonly TURN_KEY_ID?: string
  readonly TURN_KEY_API_TOKEN?: string
  readonly ICE_TTL_SECONDS?: string
  // Test only (ENVIRONMENT=test).
  readonly STACK_TEST_JWKS?: string
  /** JSON {userId: [teamId]} for primary-project users, {"<projectId>:<userId>": [teamId]} for the others; replaces Stack membership calls. */
  readonly STACK_TEST_TEAMS?: string
}
