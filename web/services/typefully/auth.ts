import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import {
  typefullyAccessForUser,
  type TypefullyAccessResult,
} from "./access";

export {
  ALLOWED_TYPEFULLY_DOMAINS,
  hasGoogleOAuthProvider,
  isAllowedTypefullyEmail,
  typefullyAccessForUser,
  type TypefullyAccessDeniedReason,
  type TypefullyAccessResult,
  type TypefullyUser,
} from "./access";

export async function requireTypefullyUserFromRequest(
  request: Request,
): Promise<TypefullyAccessResult> {
  if (!isStackConfigured()) {
    return { ok: false, reason: "auth_not_configured" };
  }

  const user = await getStackServerApp().getUser({
    tokenStore: request as unknown as { headers: { get(name: string): string | null } },
    or: "return-null",
  });
  return typefullyAccessForUser(user);
}

export async function requireTypefullyUserFromCookies(): Promise<TypefullyAccessResult> {
  if (!isStackConfigured()) {
    return { ok: false, reason: "auth_not_configured" };
  }

  const user = await getStackServerApp().getUser({ or: "return-null" });
  return typefullyAccessForUser(user);
}
