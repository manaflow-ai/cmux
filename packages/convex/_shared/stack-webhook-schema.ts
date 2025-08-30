import { z } from "zod";

/**
 * Helpers
 */
const uuid = z.uuid();
const email = z.email();
const jsonNullable = z.unknown().nullable();

/**
 * Team (server read) shape
 */
export const TeamSchema = z.object({
  id: uuid,
  display_name: z.string(),
  profile_image_url: z.string().nullable(),
  client_metadata: jsonNullable.optional(),
  client_read_only_metadata: jsonNullable.optional(),
  created_at_millis: z.number(),
  server_metadata: jsonNullable.optional(),
});

/**
 * User (server read) shape
 * Includes deprecated fields and oauth_providers as seen in webhook payloads.
 */
export const UserSchema = z.object({
  id: uuid,
  primary_email: email.nullable(),
  primary_email_verified: z.boolean(),
  primary_email_auth_enabled: z.boolean(),

  display_name: z.string().nullable(),
  selected_team: TeamSchema.nullable(),
  selected_team_id: uuid.nullable(),
  profile_image_url: z.string().nullable(),

  signed_up_at_millis: z.number(),
  last_active_at_millis: z.number(),
  has_password: z.boolean(),
  otp_auth_enabled: z.boolean(),
  passkey_auth_enabled: z.boolean(),

  client_metadata: jsonNullable,
  client_read_only_metadata: jsonNullable,
  server_metadata: jsonNullable,

  is_anonymous: z.boolean(),

  // Present in webhook payloads (hidden in docs)
  oauth_providers: z.array(
    z.object({
      id: z.string(),
      account_id: z.string(),
      email: email.nullable(),
    })
  ),
});

/**
 * User deleted payload
 */
export const UserDeletedSchema = z.object({
  id: uuid,
  teams: z.array(z.object({ id: uuid })),
});

/**
 * Team deleted payload
 */
export const TeamDeletedSchema = z.object({
  id: uuid,
});

/**
 * Team membership payload (created/deleted)
 */
export const TeamMembershipSchema = z.object({
  team_id: uuid,
  user_id: uuid,
});

/**
 * Team permission payload (created/deleted)
 * Matches permissionDefinitionIdSchema constraints loosely.
 */
export const TeamPermissionSchema = z.object({
  // Accepts system/custom permission IDs like "$update_team" or "team_member"
  id: z.string().regex(/^\$?[a-z0-9_:]+$/),
  user_id: uuid,
  team_id: uuid,
});

/**
 * Discriminated union over all supported webhook types
 * The webhook POST body is always { type, data }.
 */
export const StackWebhookPayloadSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("user.created"), data: UserSchema }),
  z.object({ type: z.literal("user.updated"), data: UserSchema }),
  z.object({ type: z.literal("user.deleted"), data: UserDeletedSchema }),

  z.object({ type: z.literal("team.created"), data: TeamSchema }),
  z.object({ type: z.literal("team.updated"), data: TeamSchema }),
  z.object({ type: z.literal("team.deleted"), data: TeamDeletedSchema }),

  z.object({
    type: z.literal("team_membership.created"),
    data: TeamMembershipSchema,
  }),
  z.object({
    type: z.literal("team_membership.deleted"),
    data: TeamMembershipSchema,
  }),

  z.object({
    type: z.literal("team_permission.created"),
    data: TeamPermissionSchema,
  }),
  z.object({
    type: z.literal("team_permission.deleted"),
    data: TeamPermissionSchema,
  }),
]);

export type StackWebhookPayload = z.infer<typeof StackWebhookPayloadSchema>;
