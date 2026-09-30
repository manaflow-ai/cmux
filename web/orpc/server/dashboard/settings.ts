import { z } from "zod";
import { getStackServerApp } from "@/app/lib/stack";
import { authed } from "./base";
import { dashboardRefusal } from "./errors";

/**
 * Account settings reads. They load the Stack user for the request's own
 * session, so a route loader and the page's server prefetch can fill the
 * settings pages before render. Writes stay on the Hexclave client SDK,
 * which applies Hexclave's user-level rules with the user's own session, and
 * invalidate these queries when they finish.
 */
async function sessionStackUser(request: Request) {
  const user = await getStackServerApp().getUser({ tokenStore: request, or: "return-null" });
  if (!user || user.isAnonymous) throw dashboardRefusal(401, "unauthorized");
  return user;
}

const emailSchema = z.object({
  id: z.string(),
  value: z.string(),
  type: z.literal("email"),
  isPrimary: z.boolean(),
  isVerified: z.boolean(),
  usedForAuth: z.boolean(),
});

const overviewSchema = z.object({
  project: z.object({
    displayName: z.string(),
    credentialEnabled: z.boolean(),
    passkeyEnabled: z.boolean(),
    magicLinkEnabled: z.boolean(),
    allowUserApiKeys: z.boolean(),
    clientUserDeletionEnabled: z.boolean(),
  }),
  emails: z.array(emailSchema),
});

export type SettingsOverview = z.output<typeof overviewSchema>;
export type SettingsEmail = z.output<typeof emailSchema>;

/** Project sign-in flags and the user's emails: the profile, auth, and account pages. */
const overview = authed
  .output(overviewSchema)
  .handler(async ({ context }) => {
    const [user, project] = await Promise.all([sessionStackUser(context.request), getStackServerApp().getProject()]);
    const channels = await user.listContactChannels();
    return {
      project: {
        displayName: project.displayName,
        credentialEnabled: project.config.credentialEnabled,
        passkeyEnabled: project.config.passkeyEnabled,
        magicLinkEnabled: project.config.magicLinkEnabled,
        allowUserApiKeys: project.config.allowUserApiKeys,
        clientUserDeletionEnabled: project.config.clientUserDeletionEnabled,
      },
      emails: channels.map((channel) => ({
        id: channel.id,
        value: channel.value,
        type: channel.type,
        isPrimary: channel.isPrimary,
        isVerified: channel.isVerified,
        usedForAuth: channel.usedForAuth,
      })),
    };
  });

const notificationCategorySchema = z.object({
  id: z.string(),
  name: z.string(),
  enabled: z.boolean(),
  canDisable: z.boolean(),
});

export type SettingsNotificationCategory = z.output<typeof notificationCategorySchema>;

const notifications = authed
  .output(z.array(notificationCategorySchema))
  .handler(async ({ context }) => {
    const categories = await (await sessionStackUser(context.request)).listNotificationCategories();
    return categories.map(({ id, name, enabled, canDisable }) => ({ id, name, enabled, canDisable }));
  });

const sessionSchema = z.object({
  id: z.string(),
  createdAt: z.string(),
  lastUsedAt: z.string().nullable(),
  isImpersonation: z.boolean(),
  isCurrentSession: z.boolean(),
  geoInfo: z.object({
    ip: z.string().nullable(),
    cityName: z.string().nullable(),
    countryCode: z.string().nullable(),
  }).nullable(),
});

export type SettingsSession = z.output<typeof sessionSchema>;

/** Active sessions; `isCurrentSession` is relative to the request's own session. */
const sessions = authed
  .output(z.array(sessionSchema))
  .handler(async ({ context }) => {
    const active = await (await sessionStackUser(context.request)).getActiveSessions();
    return active.map((session) => ({
      id: session.id,
      createdAt: session.createdAt.toISOString(),
      lastUsedAt: session.lastUsedAt ? session.lastUsedAt.toISOString() : null,
      isImpersonation: session.isImpersonation,
      isCurrentSession: session.isCurrentSession,
      geoInfo: session.geoInfo
        ? {
          ip: session.geoInfo.ip ?? null,
          cityName: session.geoInfo.cityName ?? null,
          countryCode: session.geoInfo.countryCode ?? null,
        }
        : null,
    }));
  });

const apiKeySchema = z.object({
  id: z.string(),
  description: z.string(),
  createdAt: z.string(),
  expiresAt: z.string().nullable(),
  manuallyRevokedAt: z.string().nullable(),
  lastFour: z.string(),
  whyInvalid: z.enum(["manually-revoked", "expired"]).nullable(),
});

export type SettingsApiKey = z.output<typeof apiKeySchema>;

const apiKeys = authed
  .output(z.array(apiKeySchema))
  .handler(async ({ context }) => {
    const keys = await (await sessionStackUser(context.request)).listApiKeys();
    return keys.map((key) => ({
      id: key.id,
      description: key.description,
      createdAt: key.createdAt.toISOString(),
      expiresAt: key.expiresAt ? key.expiresAt.toISOString() : null,
      manuallyRevokedAt: key.manuallyRevokedAt ? key.manuallyRevokedAt.toISOString() : null,
      lastFour: key.value.lastFour,
      whyInvalid: key.whyInvalid(),
    }));
  });

const oauthProviderSchema = z.object({
  id: z.string(),
  type: z.string(),
  email: z.string().nullable(),
  allowSignIn: z.boolean(),
  allowConnectedAccounts: z.boolean(),
});

export type SettingsOAuthProvider = z.output<typeof oauthProviderSchema>;

/** Linked OAuth providers, and the project's configured provider ids for "connect". */
const oauthProviders = authed
  .output(z.object({ linked: z.array(oauthProviderSchema), available: z.array(z.string()) }))
  .handler(async ({ context }) => {
    const [user, project] = await Promise.all([sessionStackUser(context.request), getStackServerApp().getProject()]);
    const linked = await user.listOAuthProviders();
    return {
      linked: linked.map((provider) => ({
        id: provider.id,
        type: provider.type,
        email: provider.email ?? null,
        allowSignIn: provider.allowSignIn,
        allowConnectedAccounts: provider.allowConnectedAccounts,
      })),
      available: project.config.oauthProviders.map((provider) => provider.id),
    };
  });

export const settingsRouter = { overview, notifications, sessions, apiKeys, oauthProviders };
