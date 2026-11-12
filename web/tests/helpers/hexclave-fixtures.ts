import type {
  HexclaveProjectPermission,
  HexclaveServerTeam,
  HexclaveServerUser,
  HexclaveTeamPermission,
} from "../../services/auth/hexclave/serverApi";
import type { HexclaveWebhookData, HexclaveWebhookEventType } from "../../services/auth/hexclave/webhookEvents";

/**
 * Real-shaped Hexclave payloads, copied from the inline Svix snapshots in
 * Hexclave's own e2e suite (apps/e2e/tests/backend/endpoints/api/v1/*.test.ts)
 * with the stripped UUIDs and timestamps filled in. Typed by the schemas'
 * inferred types, so a schema change upstream breaks compilation here too.
 */
export const USER_ID = "3f0d6c4e-6a0b-4d4e-9d63-1f0e7a4b2c11";
export const OTHER_USER_ID = "8b1f2a3c-4d5e-4f60-8a7b-9c0d1e2f3a4b";
export const TEAM_ID = "c2a8e9f1-7b3d-4e5f-9a1b-2c3d4e5f6a7b";
export const OTHER_TEAM_ID = "0e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b";

export function serverTeam(overrides: Partial<HexclaveServerTeam> = {}): HexclaveServerTeam {
  return {
    id: TEAM_ID,
    display_name: "Acme",
    profile_image_url: null,
    client_metadata: null,
    client_read_only_metadata: { plan: "team" },
    server_metadata: null,
    created_at_millis: 1_790_000_000_000,
    ...overrides,
  };
}

export function serverUser(overrides: Partial<HexclaveServerUser> = {}): HexclaveServerUser {
  return {
    auth_with_email: false,
    client_metadata: null,
    client_read_only_metadata: null,
    country_code: null,
    display_name: null,
    has_password: false,
    id: USER_ID,
    is_anonymous: false,
    is_restricted: false,
    last_active_at_millis: 1_790_000_100_000,
    oauth_providers: [],
    otp_auth_enabled: false,
    passkey_auth_enabled: false,
    primary_email: "test@example.com",
    primary_email_auth_enabled: false,
    primary_email_verified: false,
    profile_image_url: null,
    requires_totp_mfa: false,
    restricted_by_admin: false,
    restricted_by_admin_private_details: null,
    restricted_by_admin_reason: null,
    restricted_reason: null,
    risk_scores: { sign_up: { bot: 0, free_trial_abuse: 0 } },
    selected_team: null,
    selected_team_id: null,
    server_metadata: null,
    signed_up_at_millis: 1_790_000_000_500,
    ...overrides,
  };
}

export function teamPermission(overrides: Partial<HexclaveTeamPermission> = {}): HexclaveTeamPermission {
  return { id: "team_member", team_id: TEAM_ID, user_id: USER_ID, ...overrides };
}

export function projectPermission(overrides: Partial<HexclaveProjectPermission> = {}): HexclaveProjectPermission {
  return { id: "test_permission", user_id: USER_ID, ...overrides };
}

/** One valid `data` per event type; a `Record` over the key union forces every type to be present. */
export const validWebhookData: { readonly [T in HexclaveWebhookEventType]: HexclaveWebhookData<T> } = {
  "user.created": serverUser(),
  "user.updated": serverUser({ display_name: "Test User", selected_team: serverTeam(), selected_team_id: TEAM_ID }),
  "user.deleted": { id: USER_ID, teams: [{ id: TEAM_ID }] },
  "team.created": serverTeam(),
  "team.updated": serverTeam({ display_name: "Acme Inc" }),
  "team.deleted": { id: TEAM_ID },
  "team_membership.created": { team_id: TEAM_ID, user_id: USER_ID },
  "team_membership.deleted": { team_id: TEAM_ID, user_id: USER_ID },
  "team_permission.created": teamPermission(),
  "team_permission.deleted": teamPermission(),
  "project_permission.created": projectPermission(),
  "project_permission.deleted": projectPermission(),
};
