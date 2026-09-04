import {
  HEXCLAVE_OAUTH_PROVIDERS,
  type HexclaveOAuthProvider,
} from "../../../services/auth/hexclave/auth";
import type { AuthIntl } from "./auth-intl";
import { HiddenReturnTo } from "./auth-fields";
import { ProviderMark } from "./provider-marks";

const PROVIDER_LABEL_KEY: Readonly<
  Record<HexclaveOAuthProvider, string>
> = {
  google: "providerGoogle",
  github: "providerGithub",
  apple: "providerApple",
};

/**
 * Each provider is its own POST form rather than a link.
 *
 * Starting the flow mints a PKCE verifier and writes a cookie, so a GET would
 * let a prefetch or a link preview consume the attempt before the visitor
 * clicks, and would let another site start the flow in this browser.
 */
export function OAuthButtons({
  intl,
  returnTo,
  providers = HEXCLAVE_OAUTH_PROVIDERS,
}: {
  intl: AuthIntl;
  returnTo: string | null;
  providers?: readonly HexclaveOAuthProvider[];
}) {
  return (
    <div className="flex flex-col gap-2">
      {providers.map((provider) => (
        <form key={provider} method="post" action={`/handler/oauth/${provider}`}>
          <HiddenReturnTo value={returnTo} />
          <button
            type="submit"
            className="flex min-h-10 w-full items-center justify-center gap-2.5 border border-border bg-background px-4 text-sm font-medium text-foreground hover:bg-code-bg"
          >
            <ProviderMark provider={provider} />
            {intl.t("continueWith", {
              provider: intl.t(PROVIDER_LABEL_KEY[provider]),
            })}
          </button>
        </form>
      ))}
    </div>
  );
}
