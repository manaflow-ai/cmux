import { vaultSignInHref, localizedVaultPath } from "@/app/lib/vault-auth";
import { rpc } from "./rpc";

/** The signed-in user and build flags; loaded once by the shell's `beforeLoad`. */
export const sessionQuery = rpc.account.session.queryOptions({
  staleTime: 5 * 60_000,
  retry: false,
});

/** Full-page navigation to sign-in that returns to `path` afterwards. */
export function signInHref(locale: string, path: string): string {
  return vaultSignInHref(localizedVaultPath(locale, path));
}
