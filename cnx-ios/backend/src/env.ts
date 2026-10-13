import type { TeamHub } from "./team-hub.ts"

export interface Env {
  readonly ENVIRONMENT: string
  readonly API_VERSION: string
  readonly STACK_PROJECT_ID: string
  readonly STACK_PUBLISHABLE_CLIENT_KEY: string
  /** Where a Stack team invitation email links to (must be a trusted domain of the Stack project). */
  readonly INVITE_CALLBACK_URL: string
  readonly TEAM_HUB: DurableObjectNamespace<TeamHub>
  /** Absent in tests: the memory store is used instead. */
  readonly HYPERDRIVE?: Hyperdrive
  /** Optional: when set, membership and invites use the Stack server API instead of the caller's token. */
  readonly STACK_SECRET_SERVER_KEY?: string
  readonly TURN_KEY_ID?: string
  readonly TURN_KEY_API_TOKEN?: string
  readonly ICE_TTL_SECONDS?: string
  // Test only (ENVIRONMENT=test).
  readonly STACK_TEST_JWKS?: string
  /** JSON {userId: [teamId]} used instead of Stack membership calls. */
  readonly STACK_TEST_TEAMS?: string
}
