import { z } from "zod";
import { MAX_INVITE_EMAILS, MAX_INVITE_LINK_USES } from "./limits";

const displayName = z.string().trim().min(1).max(120);
const teamRole = z.enum(["admin", "member"]);

// Hosted images or small inline images; the 16 KB body cap bounds data URLs.
const profileImageUrl = z.string().max(15_000).refine(
  (value) => /^https:\/\/[^\s]+$/u.test(value) || /^data:image\/(?:png|jpeg|webp|gif);base64,[A-Za-z0-9+/]+=*$/u.test(value),
  { message: "Expected an https URL or a base64 image data URL." },
).nullable();

export const createTeamBody = z.object({ displayName }).strict();

export const updateTeamBody = z.object({
  displayName: displayName.optional(),
  profileImageUrl: profileImageUrl.optional(),
}).strict();

export const inviteBody = z.object({
  emails: z.array(z.string().trim().max(254).pipe(z.email())).min(1).max(MAX_INVITE_EMAILS),
  role: teamRole,
}).strict();

export const createLinkBody = z.object({
  expiresInDays: z.union([z.literal(1), z.literal(7), z.literal(30), z.null()]),
  maxUses: z.number().int().min(1).max(MAX_INVITE_LINK_USES).nullable(),
}).strict();

export const memberRoleBody = z.object({ role: teamRole }).strict();

export const acceptBody = z.object({ code: z.string().trim().min(1).max(512) }).strict();

export const uuidParam = z.uuid();
