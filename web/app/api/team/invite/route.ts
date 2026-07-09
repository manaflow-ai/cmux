import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import {
  readBoundedJson,
  sendTeamInvite,
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
    const result = await sendTeamInvite({
      user,
      request,
      email: record.email,
      locale,
    });
    return teamInviteJson(result);
  } catch (error) {
    return teamInviteErrorResponse(error);
  }
}
