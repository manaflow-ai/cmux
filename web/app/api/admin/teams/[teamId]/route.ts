import { NextRequest } from "next/server";
import { getStackServerApp } from "../../../../../app/lib/stack";
import { adminJsonResponse, requireAdmin } from "../../../../../services/admin/routeAuth";

/** GET /api/admin/teams/:teamId — team metadata and member directory for admins. */
export async function GET(request: NextRequest, context: { params: Promise<{ teamId: string }> }) {
  const gate = await requireAdmin(request);
  if (!gate.ok) return gate.response;
  const { teamId } = await context.params;
  if (!teamId || teamId.length > 200) return adminJsonResponse({ error: "invalid_team_id" }, 400);
  const app = getStackServerApp();
  const team = await app.getTeam(teamId);
  if (!team) return adminJsonResponse({ error: "team_not_found" }, 404);
  const users = await team.listUsers();
  const members = await Promise.all(users.map(async (member) => {
    const user = await app.getUser(member.id);
    return {
      id: member.id,
      displayName: user?.displayName ?? null,
      email: user?.primaryEmail ?? null,
      emailVerified: user?.primaryEmailVerified ?? false,
      signedUpAt: user?.signedUpAt?.toISOString() ?? null,
    };
  }));
  return adminJsonResponse({
    team: {
      id: team.id,
      displayName: team.displayName,
      createdAt: team.createdAt?.toISOString() ?? null,
      metadata: JSON.stringify(team.clientReadOnlyMetadata ?? null),
      serverMetadata: JSON.stringify(team.serverMetadata ?? null),
    },
    members,
  });
}
