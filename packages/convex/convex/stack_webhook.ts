import { Webhook } from "svix";
import { env } from "../_shared/convex-env";
import {
  StackWebhookPayloadSchema,
  type StackWebhookPayload,
} from "../_shared/stack-webhook-schema";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";

function undefIfNull<T>(value: T | null | undefined): T | undefined {
  return value === null || value === undefined ? undefined : value;
}

export const stackWebhook = httpAction(async (ctx, req) => {
  // Read payload text to preserve signature integrity
  const payload = await req.text();

  // Verify Svix signature
  let verified: unknown;
  try {
    const svix = new Webhook(env.STACK_WEBHOOK_SECRET);
    verified = svix.verify(payload, {
      "svix-id": req.headers.get("svix-id") ?? "",
      "svix-timestamp": req.headers.get("svix-timestamp") ?? "",
      "svix-signature": req.headers.get("svix-signature") ?? "",
    });
  } catch (_err) {
    return new Response("invalid signature", { status: 400 });
  }

  // Parse payload against our shared schema
  let event: StackWebhookPayload;
  try {
    event = StackWebhookPayloadSchema.parse(verified);
  } catch (_err) {
    return new Response("invalid payload", { status: 400 });
  }

  switch (event.type) {
    case "user.created":
    case "user.updated": {
      const u = event.data;
      const oauthProviders = u.oauth_providers?.map((p) => ({
        id: p.id,
        accountId: p.account_id,
        email: undefIfNull(p.email),
      }));
      await ctx.runMutation(internal.stack.upsertUser, {
        id: u.id,
        primaryEmail: undefIfNull(u.primary_email || undefined),
        primaryEmailVerified: u.primary_email_verified,
        primaryEmailAuthEnabled: u.primary_email_auth_enabled,
        displayName: undefIfNull(u.display_name || undefined),
        selectedTeamId: undefIfNull(u.selected_team_id || undefined),
        selectedTeamDisplayName: undefIfNull(
          u.selected_team?.display_name || undefined
        ),
        selectedTeamProfileImageUrl: undefIfNull(
          u.selected_team?.profile_image_url || undefined
        ),
        profileImageUrl: undefIfNull(u.profile_image_url || undefined),
        signedUpAtMillis: u.signed_up_at_millis,
        lastActiveAtMillis: u.last_active_at_millis,
        hasPassword: u.has_password,
        otpAuthEnabled: u.otp_auth_enabled,
        passkeyAuthEnabled: u.passkey_auth_enabled,
        clientMetadata: undefIfNull(u.client_metadata),
        clientReadOnlyMetadata: undefIfNull(u.client_read_only_metadata),
        serverMetadata: undefIfNull(u.server_metadata),
        isAnonymous: u.is_anonymous,
        oauthProviders,
      });
      break;
    }
    case "user.deleted": {
      const u = event.data;
      await ctx.runMutation(internal.stack.deleteUser, { id: u.id });
      break;
    }
    case "team.created":
    case "team.updated": {
      const t = event.data;
      await ctx.runMutation(internal.stack.upsertTeam, {
        id: t.id,
        displayName: undefIfNull(t.display_name || undefined),
        profileImageUrl: undefIfNull(t.profile_image_url || undefined),
        clientMetadata: undefIfNull(t.client_metadata),
        clientReadOnlyMetadata: undefIfNull(t.client_read_only_metadata),
        serverMetadata: undefIfNull(t.server_metadata),
        createdAtMillis: t.created_at_millis,
      });
      break;
    }
    case "team.deleted": {
      const t = event.data;
      await ctx.runMutation(internal.stack.deleteTeam, { id: t.id });
      break;
    }
    case "team_membership.created": {
      const m = event.data;
      await ctx.runMutation(internal.stack.ensureMembership, {
        teamId: m.team_id,
        userId: m.user_id,
      });
      break;
    }
    case "team_membership.deleted": {
      const m = event.data;
      await ctx.runMutation(internal.stack.deleteMembership, {
        teamId: m.team_id,
        userId: m.user_id,
      });
      break;
    }
    case "team_permission.created": {
      const p = event.data;
      await ctx.runMutation(internal.stack.ensurePermission, {
        teamId: p.team_id,
        userId: p.user_id,
        permissionId: p.id,
      });
      break;
    }
    case "team_permission.deleted": {
      const p = event.data;
      await ctx.runMutation(internal.stack.deletePermission, {
        teamId: p.team_id,
        userId: p.user_id,
        permissionId: p.id,
      });
      break;
    }
    default: {
      // Should never happen due to schema
      break;
    }
  }

  return new Response("ok", { status: 200 });
});
