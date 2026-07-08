import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized } from "../../../../services/vms/auth";
import {
  deleteCmuxAccountData,
  markStackUserDeletionInProgress,
} from "../../../../services/account/deletion";
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
  await markStackUserDeletionInProgress(user);

  await deleteCmuxAccountData({ userId: user.id });
  await deletePostHogPersonData(user.id);
  await user.delete();
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
