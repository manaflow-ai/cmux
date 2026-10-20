import type { DashboardSessionUser, JoinViewer } from "@/app/lib/dashboard-auth";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";

export type JoinPageOutcome =
  | { readonly kind: "render"; readonly user: DashboardSessionUser }
  | { readonly kind: "sign_in"; readonly href: string }
  | { readonly kind: "retry"; readonly retryHref: string };

/** What the invite page does for this viewer. A Stack outage retries the same link. */
export function joinPageOutcome(viewer: JoinViewer, locale: string, token: string): JoinPageOutcome {
  const joinPath = localizedVaultPath(locale, `/join/${encodeURIComponent(token)}`);
  if (viewer.kind === "user") return { kind: "render", user: viewer.user };
  if (viewer.kind === "unavailable") return { kind: "retry", retryHref: joinPath };
  return { kind: "sign_in", href: vaultSignInHref(joinPath) };
}
