import { z } from "zod";

// Shared shapes for the Subrouter cloud API. Keeping them in one module means
// the OpenAPI document and the Go client contract test agree by construction.

export const srProviderSchema = z.enum(["codex", "claude", "gemini", "apikey"]);
export type SRProvider = z.infer<typeof srProviderSchema>;

export const srAccountSchema = z.object({
  provider: srProviderSchema,
  // The account's stable identity: an email for OAuth accounts, a label for API
  // keys. Unique per team and provider.
  accountLabel: z.string().min(1).max(320),
  updatedAt: z.string(),
});
export type SRAccount = z.infer<typeof srAccountSchema>;

// The credential blob is opaque to the server: it is sealed on write and only
// returned to a member of the owning team. Capping it keeps a malformed client
// from writing unbounded rows.
export const srAccountUploadSchema = z.object({
  provider: srProviderSchema,
  accountLabel: z.string().min(1).max(320),
  credential: z.string().min(1).max(64_000),
});

export const srAccountsPushInputSchema = z.object({
  accounts: z.array(srAccountUploadSchema).min(1).max(100),
});

export const srAccountsPushOutputSchema = z.object({
  teamId: z.string(),
  uploaded: z.number().int().nonnegative(),
  // Accounts already present are updated in place rather than duplicated, so
  // the client can tell a first upload from a refresh.
  updated: z.number().int().nonnegative(),
});

export const srAccountsListOutputSchema = z.object({
  teamId: z.string(),
  accounts: z.array(srAccountSchema),
});

export const srDeviceStartOutputSchema = z.object({
  // Shown to the human and typed into the browser.
  userCode: z.string(),
  // Held by the CLI and exchanged on poll. Never displayed.
  deviceCode: z.string(),
  verificationUri: z.string(),
  expiresInSeconds: z.number().int().positive(),
  intervalSeconds: z.number().int().positive(),
});

export const srDevicePollInputSchema = z.object({
  deviceCode: z.string().min(1),
});

export const srDevicePollOutputSchema = z.object({
  // "pending" until a signed-in human approves, then "approved" exactly once.
  status: z.enum(["pending", "approved", "expired"]),
  teamId: z.string().nullable(),
  userId: z.string().nullable(),
});
