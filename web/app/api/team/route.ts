import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import {
  createTeamForUser,
  loadTeamSummary,
  readBoundedJson,
  teamInviteErrorResponse,
  teamInviteJson,
  updateTeamName,
  type StackTeamUserLike,
} from "@/services/team/invites";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  if (!isStackConfigured()) return teamInviteJson({ error: "service_unavailable" }, 503);
  try {
    const user = await getStackServerApp().getUser({ or: "return-null" }) as StackTeamUserLike | null;
    if (!user) return teamInviteJson({ error: "unauthorized" }, 401);
    const body = await readBoundedJson(request);
    const record = body && typeof body === "object" ? body as Record<string, unknown> : {};
    if (record.action === "create") {
      await createTeamForUser(user, record.displayName);
      return teamInviteJson({ ok: true });
    }
    if (record.action === "rename") {
      return teamInviteJson(await updateTeamName(user, record.displayName));
    }
    return teamInviteJson(await loadTeamSummary(user));
  } catch (error) {
    return teamInviteErrorResponse(error);
  }
}
