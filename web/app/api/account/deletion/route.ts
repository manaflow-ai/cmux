import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized } from "../../../../services/vms/auth";
import {
  deleteCmuxAccountData,
  markStackUserDeletionInProgress,
  type StackAccountDeletionMetadataUser,
} from "../../../../services/account/deletion";
import {
  assertPostHogDeletionConfigured,
  deletePostHogPersonData,
} from "../../../../services/analytics/posthogDeletion";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function DELETE(request: Request): Promise<Response> {
  return deleteAccountWithDependencies(request, accountDeletionRouteDependencies);
}

type NativeTokenStore = { accessToken: string; refreshToken: string };
type StackAccountDeletionRouteUser = StackAccountDeletionMetadataUser & {
  readonly id: string;
  delete(): Promise<void>;
};

export type AccountDeletionRouteDependencies = {
  readonly isStackConfigured: () => boolean;
  readonly getUser: (tokenStore: NativeTokenStore) => Promise<StackAccountDeletionRouteUser | null>;
  readonly assertPostHogDeletionConfigured: typeof assertPostHogDeletionConfigured;
  readonly markStackUserDeletionInProgress: typeof markStackUserDeletionInProgress;
  readonly deleteCmuxAccountData: typeof deleteCmuxAccountData;
  readonly deletePostHogPersonData: typeof deletePostHogPersonData;
};

const accountDeletionRouteDependencies: AccountDeletionRouteDependencies = {
  isStackConfigured,
  getUser: async (tokenStore) => await getStackServerApp().getUser({ tokenStore }),
  assertPostHogDeletionConfigured,
  markStackUserDeletionInProgress,
  deleteCmuxAccountData,
  deletePostHogPersonData,
};

export async function deleteAccountWithDependencies(
  request: Request,
  dependencies: AccountDeletionRouteDependencies,
): Promise<Response> {
  if (!dependencies.isStackConfigured()) return unauthorized();

  const tokenStore = nativeTokenStore(request);
  if (!tokenStore) return unauthorized();

  const user = await dependencies.getUser(tokenStore);
  if (!user) return unauthorized();

  dependencies.assertPostHogDeletionConfigured();
  await dependencies.markStackUserDeletionInProgress(user);

  await dependencies.deleteCmuxAccountData({ userId: user.id });
  await dependencies.deletePostHogPersonData(user.id);
  await user.delete();
  return jsonResponse({ ok: true });
}

function nativeTokenStore(request: Request): NativeTokenStore | null {
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
