// A Cloud or remote chat's GitHub sign-in on its own machine (logins done right; Leo, 2026-11-22:
// "we likewise want gh auth or device stuff to be much more convienient ui/ux wise ... if we host
// the browser and the app at the same time and the cloud product... theres no reason for us not
// only to be able to have s*** side by side opened where it's convienient, but also great ui/ux for
// onboarding them and if they want to add another one of their personal accounts. this is simply
// logins, done righr."). One click runs `gh auth login --web` on the chat's machine
// (`_acpmux/account/sign_in`, which names the chat so acpmux forwards it there and only that
// machine's owner may run it), GitHub's device page opens beside the chat, and the shared
// DeviceSignInCard shows the one-time code until the approval lands. The card's state holds the
// code (useAccountSignIn.ts); this transport never keeps or logs it.
import {
  ACCOUNT_ACTIONS,
  type AccountRunParams,
  type AccountRunResult,
  type SignInFinishWire,
  type SignInStartWire,
} from "../../pages/shared/signIn/accountSignIn";
import type { AccountSignInTransport } from "../../pages/shared/signIn/useAccountSignIn";
import type { AcpmuxDirectClient } from "./direct";

/// The one page this sign-in opens: GitHub's device page, exactly (AgentPaneSignInPage.swift admits
/// no other github.com page).
export const GITHUB_DEVICE_PAGE = "https://github.com/login/device";

/// `raw` is exactly GitHub's device page (no query, fragment, port or user info).
export function isGitHubDevicePage(raw: unknown): raw is string {
  if (typeof raw !== "string") return false;
  try {
    const url = new URL(raw);
    return url.toString() === GITHUB_DEVICE_PAGE && !url.search && !url.hash;
  } catch {
    return false;
  }
}

export type GitHubSignInClient = Pick<
  AcpmuxDirectClient,
  "accountSignInStart" | "accountSignInFinish" | "accountSignInCancel"
>;

type Options = {
  sessionId: string;
  /// The live client while the pane still shows the chat; undefined once it moved on.
  currentClient: () => GitHubSignInClient | undefined;
  /// Opens the device page beside the chat (the host lets the start that took the click open it).
  openURL: (url: string) => void;
};

/// A refusal that means the machine (or the host between) has no such method: the card then keeps
/// the older ways in (an empty start answer makes useAccountSignIn fall back).
function methodMissing(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return code === -32601 || code === "transport.method_refused" || code === "remote.unsupported";
}

type Step = { ok: true; reply: unknown } | { ok: false; error: unknown } | { ok: "missing" };

/// The sign-in card's transport over the chat's own connection. Only `github` starts here; every
/// other gesture (Use, Sign out, Remove) is Settings > Accounts' and is refused.
export function cloudGitHubSignIn({ sessionId, currentClient, openURL }: Options): AccountSignInTransport {
  const call = async (step: (client: GitHubSignInClient) => Promise<unknown>): Promise<Step> => {
    const client = currentClient();
    if (!client) return { ok: false, error: { reason: "unknown_session" } };
    try {
      return { ok: true, reply: await step(client) };
    } catch (error) {
      return methodMissing(error) ? { ok: "missing" } : { ok: false, error };
    }
  };
  return {
    async run(params: AccountRunParams): Promise<AccountRunResult> {
      switch (params.action) {
        case ACCOUNT_ACTIONS.start: {
          if (params.family !== "github") return { ok: false, error: { reason: "unsupported" } };
          const step = await call((client) => client.accountSignInStart("github", sessionId));
          if (step.ok === false) return step;
          if (step.ok === "missing") return { ok: true, value: {} };
          // The page opens once, on the click's credit; no other page is opened.
          const url = (step.reply as { url?: unknown } | null)?.url;
          if (isGitHubDevicePage(url)) openURL(GITHUB_DEVICE_PAGE);
          return { ok: true, value: { signIn: step.reply as SignInStartWire } };
        }
        case ACCOUNT_ACTIONS.finish: {
          const loginId = params.loginId;
          if (!loginId) return { ok: false, error: { reason: "unknown_login" } };
          const step = await call((client) => client.accountSignInFinish(loginId, sessionId));
          if (step.ok === false) return step;
          if (step.ok === "missing") return { ok: false, error: { reason: "unsupported" } };
          return { ok: true, value: { finished: step.reply as SignInFinishWire } };
        }
        case ACCOUNT_ACTIONS.cancel: {
          const loginId = params.loginId;
          if (loginId) await call((client) => client.accountSignInCancel(loginId, sessionId));
          return { ok: true, value: {} };
        }
        default:
          return { ok: false, error: { reason: "unsupported" } };
      }
    },
  };
}
