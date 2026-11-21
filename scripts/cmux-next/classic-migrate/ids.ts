import { createHash } from "node:crypto"

// NEXT ids are derived from the Stack identity, so a classic subject maps to its NEXT ids with no lookup.
// Same derivation as backend/apps/api/src/domains/user.ts (userIdFor, personalTeamIdFor, stackTeamIdFor) and
// cmux-platform src/server/auth/Ids.ts; copied, since user.ts pulls in the backend's workspace packages.

const hex20 = (s: string) => createHash("sha256").update(s).digest("hex").slice(0, 20)

export const userIdFor = (stackProjectId: string, stackUserId: string) =>
  `user_${hex20(`stack:${stackProjectId}:${stackUserId}`)}`

/** `userId` is the NEXT user id (user_…), not the Stack one. */
export const personalTeamIdFor = (userId: string) => `team_${hex20(`personal:${userId}`)}`

export const sharedTeamIdFor = (stackProjectId: string, stackTeamId: string) =>
  `team_${hex20(`stack-team:${stackProjectId}:${stackTeamId}`)}`

/** One migration id per (project, subject): re-planning the same subject keeps the idempotency keys of every request. */
export const migrationIdFor = (stackProjectId: string, subject: { kind: "user" | "team"; id: string }) =>
  `mig_${hex20(`classic-migration:${stackProjectId}:${subject.kind}:${subject.id}`)}`
