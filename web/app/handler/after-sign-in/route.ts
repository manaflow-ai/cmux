import { cookies } from "next/headers";
import {
  promoteStackUserFromAnonymousWithDeletionGuard,
  stackServerApp,
} from "../../lib/stack";
import { env } from "../../env";
import { applyPendingEmailGrants } from "../../../services/admin/proGrants";
import { claimPendingProBilling } from "../../../services/billing/purchase";
import { postgresNativeSignInCodeStore } from "../../lib/native-sign-in-code-store";
import { makeAfterSignInHandler } from "./handler";


export const GET = makeAfterSignInHandler({
  nativeSignInCodeStore: postgresNativeSignInCodeStore(),
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  stackServerApp,
  getCookieStore: cookies,
  promoteVerifiedAnonymousUser: promoteStackUserFromAnonymousWithDeletionGuard,
  claimVerifiedBilling: async (userId) => {
    if (!stackServerApp) return;
    const user = await stackServerApp.getUser(userId);
    if (user) await claimPendingProBilling(user);
  },
  applyAdminGrants: async (userId, email) => {
    await applyPendingEmailGrants({ id: userId, primaryEmail: email });
  },
});
