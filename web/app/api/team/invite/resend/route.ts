import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import {
  readBoundedJson,
  resendTeamInvite,
  teamInviteErrorResponse,
  teamInviteJson,
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
    const locale = typeof record.locale === "string" && record.locale.trim() ? record.locale.trim() : "en";
    return teamInviteJson(await resendTeamInvite({
      user,
      request,
      invitationId: record.invitationId,
      locale,
    }));
  } catch (error) {
    return teamInviteErrorResponse(error);
  }
}
