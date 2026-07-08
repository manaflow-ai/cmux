import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized } from "../../../../services/vms/auth";
import { deleteCmuxAccountData } from "../../../../services/account/deletion";
import {
  assertPostHogDeletionConfigured,
  deletePostHogPersonData,
} from "../../../../services/analytics/posthogDeletion";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function DELETE(request: Request): Promise<Response> {
  if (!isStackConfigured()) return unauthorized();

  const tokenStore = nativeTokenStore(request);
  if (!tokenStore) return unauthorized();

  const user = await getStackServerApp().getUser({ tokenStore });
  if (!user) return unauthorized();

  assertPostHogDeletionConfigured();

  const cleanupInput = {
    userId: user.id,
    teamIds: await stackTeamIds(user),
  };
  await deleteCmuxAccountData(cleanupInput);
  await user.delete();
  await deleteCmuxAccountData(cleanupInput);
  await deletePostHogPersonData(user.id);
  return jsonResponse({ ok: true });
}

function nativeTokenStore(request: Request): { accessToken: string; refreshToken: string } | null {
  const authHeader = request.headers.get("authorization");
  const refreshHeader = request.headers.get("x-stack-refresh-token");
  if (!authHeader?.toLowerCase().startsWith("bearer ") || !refreshHeader) {
    return null;
  }

  const accessToken = authHeader.slice("bearer ".length).trim();
  const refreshToken = refreshHeader.trim();
  if (!accessToken || !refreshToken) return null;
  return { accessToken, refreshToken };
}

type StackAccountDeletionUser = {
  readonly id: string;
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
};

async function stackTeamIds(user: StackAccountDeletionUser): Promise<readonly string[]> {
  const ids = new Set<string>();
  const selectedTeamId = teamId(user.selectedTeam);
  if (selectedTeamId) ids.add(selectedTeamId);
  if (typeof user.listTeams === "function") {
    for (const team of await user.listTeams()) {
      const id = teamId(team);
      if (id) ids.add(id);
    }
  }
  return [...ids];
}

function teamId(team: unknown): string | null {
  if (!team || typeof team !== "object") return null;
  const id = (team as { id?: unknown }).id;
  return typeof id === "string" && id.length > 0 ? id : null;
}
