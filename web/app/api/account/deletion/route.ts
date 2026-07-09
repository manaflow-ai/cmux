import { after } from "next/server";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized } from "../../../../services/vms/auth";
import {
  enqueueAccountDeletion,
  markStackUserDeletionInProgress,
  type StackAccountDeletionMetadataUser,
} from "../../../../services/account/deletion";
import {
  assertPostHogDeletionConfigured,
} from "../../../../services/analytics/posthogDeletion";
import { processAccountDeletionForUser } from "../../../../services/account/deletionProcessor";

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
  readonly enqueueAccountDeletion: typeof enqueueAccountDeletion;
  readonly processAccountDeletionForUser: typeof processAccountDeletionForUser;
  readonly scheduleAfterResponse: (callback: () => Promise<void>) => void;
};

const accountDeletionRouteDependencies: AccountDeletionRouteDependencies = {
  isStackConfigured,
  getUser: async (tokenStore) => await getStackServerApp().getUser({ tokenStore }),
  assertPostHogDeletionConfigured,
  markStackUserDeletionInProgress,
  enqueueAccountDeletion,
  processAccountDeletionForUser,
  scheduleAfterResponse: after,
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
  const deletion = await dependencies.enqueueAccountDeletion({ userId: user.id });

  if (deletion.status !== "completed") {
    try {
      await dependencies.markStackUserDeletionInProgress(user);
    } catch (error) {
      console.error("[account-deletion] Stack metadata mark failed after enqueue", {
        userIdHash: deletion.userIdHash,
        error,
      });
    }
    dependencies.scheduleAfterResponse(async () => {
      try {
        await dependencies.processAccountDeletionForUser({ userId: user.id });
      } catch (error) {
        console.error("[account-deletion] background job failed", {
          userIdHash: deletion.userIdHash,
          error,
        });
      }
    });
  }

  return jsonResponse({ ok: true, status: deletion.status }, deletion.status === "completed" ? 200 : 202);
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
