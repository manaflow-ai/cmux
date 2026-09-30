import { z } from "zod";
import type {
  TeamDetail,
  TeamInvitation,
  TeamInviteLink,
  TeamMember,
  TeamViewerPermissions,
} from "@/services/teams/types";

export const teamRoleSchema = z.enum(["admin", "member"]);

const permissionsSchema = z.object({
  updateTeam: z.boolean(),
  deleteTeam: z.boolean(),
  inviteMembers: z.boolean(),
  readMembers: z.boolean(),
  removeMembers: z.boolean(),
  manageApiKeys: z.boolean(),
  manageBilling: z.boolean(),
}) satisfies z.ZodType<TeamViewerPermissions>;

const memberSchema = z.object({
  userId: z.string(),
  displayName: z.string().nullable(),
  email: z.string().nullable(),
  profileImageUrl: z.string().nullable(),
  role: teamRoleSchema,
  isViewer: z.boolean(),
}) satisfies z.ZodType<TeamMember>;

export const invitationSchema = z.object({
  id: z.string(),
  email: z.string().nullable(),
  role: teamRoleSchema,
  expiresAt: z.string(),
}) satisfies z.ZodType<TeamInvitation>;

export const inviteLinkSchema = z.object({
  id: z.string(),
  role: z.literal("member"),
  createdAt: z.string(),
  createdByUserId: z.string(),
  expiresAt: z.string().nullable(),
  maxUses: z.number().nullable(),
  useCount: z.number(),
}) satisfies z.ZodType<TeamInviteLink>;

export const teamDetailSchema = z.object({
  team: z.object({ id: z.string(), displayName: z.string(), profileImageUrl: z.string().nullable() }),
  viewer: z.object({ userId: z.string(), role: teamRoleSchema, permissions: permissionsSchema }),
  members: z.array(memberSchema),
  invitations: z.array(invitationSchema),
  links: z.array(inviteLinkSchema),
  billing: z.object({
    planId: z.string().nullable(),
    seats: z.number().nullable(),
    memberCount: z.number(),
    hasActiveSubscription: z.boolean(),
  }),
}) satisfies z.ZodType<TeamDetail>;

/** One entry of the team catalog (`GET /api/subrouter/teams`). */
export const teamCatalogEntrySchema = z.object({
  id: z.string(),
  name: z.string(),
  personal: z.boolean(),
  permissions: z.object({ use: z.boolean(), manageAccounts: z.boolean() }),
  // Billing fields are computed only by the browser catalog source.
  planId: z.string().nullable().optional(),
  seats: z.number().nullable().optional(),
  role: teamRoleSchema.optional(),
  canManageBilling: z.boolean().optional(),
});

export const teamCatalogSchema = z.object({
  selectedTeamId: z.string().nullable(),
  teams: z.array(teamCatalogEntrySchema),
});

export type TeamCatalog = z.output<typeof teamCatalogSchema>;
export type TeamCatalogEntry = z.output<typeof teamCatalogEntrySchema>;
