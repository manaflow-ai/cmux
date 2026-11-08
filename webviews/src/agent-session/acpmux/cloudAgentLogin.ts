import { agentKey } from "../shared/agentKey";
import type { AcpmuxDirectClient } from "./direct";

// A Cloud chat's own sign-in (Leo 2026-11-01, on the one-click sign-in: "yes those are important"):
// a turn that failed because the agent on the user's Cloud machine is not signed in runs that
// agent's own login ON the machine (acpmux `_acpmux/agent_login/*`), never a copy of this Mac's
// login. The card (CloudSignIn.tsx) drives it; this module is its wire and its rules.

/// The harnesses whose login acpmux runs on the machine.
export type LoginAgent = "claude" | "codex";

/// `_acpmux/agent_login/start`'s answer: the page to open, Codex's device code, whether the page
/// gives a code to paste back (Claude), and when the login lapses. `autoUrl` is Claude's automatic
/// page, whose approve sends the code straight to Claude's own listener on the machine
/// (`http://localhost:<callbackPort>/callback` there): opened in a tab whose localhost is that
/// machine, it signs Claude in with no code to paste.
export type LoginStart = {
  loginId: string;
  url: string;
  autoUrl?: string;
  callbackPort?: number;
  userCode?: string;
  needsCode: boolean;
  expiresAtMs?: number;
};

/// Why a login step failed, as the card words it (acpmux's `data.reason`; anything else is `failed`).
export type LoginFailure =
  | "bad_code"
  | "expired"
  | "shared_machine"
  | "cli_missing"
  | "busy"
  | "remote_refused"
  | "unknown_session"
  | "unsupported"
  | "failed";

/// The hosts a sign-in page may be on. The page the machine's CLI names is opened on this Mac, so
/// only its provider's own sign-in hosts, over https.
export const SIGN_IN_HOSTS: ReadonlySet<string> = new Set([
  "claude.com",
  "claude.ai",
  "platform.claude.com",
  "console.anthropic.com",
  "auth.anthropic.com",
  "auth.openai.com",
]);

/// `raw` as a URL the card may open: https, no user info, on ``SIGN_IN_HOSTS``; else undefined.
export function signInURL(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:" || url.username || url.password || url.port) return undefined;
  return SIGN_IN_HOSTS.has(url.hostname.toLowerCase()) ? url.toString() : undefined;
}

/// `browser.openIn`'s browser for Claude's automatic page: a Chromium tab of this app whose
/// localhost is the chat's machine (AgentPaneSignInPage.swift).
export const SIGN_IN_ON_MACHINE = "cmux-chat-machine";

/// `raw` as Claude's automatic page (``LoginStart/autoUrl``): a ``signInURL`` whose one
/// `redirect_uri` is exactly `http://localhost:<port>/callback`, and that port; else undefined.
/// acpmux checks the same (`agent_login::parse::auto_url`), and so does the host before it opens it.
export function autoSignIn(raw: unknown): { url: string; port: number } | undefined {
  const url = signInURL(raw);
  if (!url) return undefined;
  const redirects = new URL(url).searchParams.getAll("redirect_uri");
  if (redirects.length !== 1) return undefined;
  const match = /^http:\/\/localhost:([1-9][0-9]{0,4})\/callback$/.exec(redirects[0]!);
  const port = match ? Number(match[1]) : NaN;
  return port >= 1 && port <= 65535 ? { url, port } : undefined;
}

/// The reason a login step's refusal names (`data.reason`), as the card's failure.
export function loginFailure(error: unknown): LoginFailure {
  if (methodMissing(error)) return "unsupported";
  const reason = (error as { reason?: unknown } | null)?.reason;
  switch (reason) {
    case "bad_code":
    case "expired":
    case "shared_machine":
    case "cli_missing":
    case "busy":
    case "remote_refused":
    case "unknown_session":
      return reason;
    // The login the card holds is gone (acpmux restarted, or it lapsed): start again.
    case "unknown_login":
      return "expired";
    case "unsupported_agent":
    case "unsupported":
      return "unsupported";
    default:
      return "failed";
  }
}

/// A daemon (or host) without the method: the sign-in is not offered (today's card stays).
function methodMissing(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  // acpmux's unknown method, the host's allowlist, or a remote chat's wire without the relay.
  return code === -32601 || code === "transport.method_refused" || code === "remote.unsupported";
}

function startOf(reply: unknown): LoginStart | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const value = reply as Record<string, unknown>;
  if (typeof value.loginId !== "string" || !value.loginId) return undefined;
  const url = signInURL(value.url);
  if (!url) return undefined;
  const auto = autoSignIn(value.autoUrl);
  return {
    loginId: value.loginId,
    url,
    // Only when acpmux named the same port the page's redirect does.
    ...(auto && value.callbackPort === auto.port ? { autoUrl: auto.url, callbackPort: auto.port } : {}),
    ...(typeof value.userCode === "string" && value.userCode ? { userCode: value.userCode } : {}),
    needsCode: value.needsCode === true,
    ...(typeof value.expiresAtMs === "number" ? { expiresAtMs: value.expiresAtMs } : {}),
  };
}

type LoginClient = Pick<
  AcpmuxDirectClient,
  | "selectedSession"
  | "resendPrompt"
  | "send"
  | "agentLoginStart"
  | "agentLoginFinish"
  | "agentLoginApiKey"
  | "agentLoginCancel"
>;

/// What the card calls. Every step that sends the failed prompt again takes the click's gesture
/// first (`reserve`, inside the click handler), and none sends without one.
export type CloudSignIn = {
  agent: LoginAgent;
  /// Starts the login on the machine. Throws a ``LoginFailure`` (as `{failure}`).
  start(): Promise<LoginStart>;
  /// Opens the sign-in page in a cmux browser tab. Right after `start` it needs no click of its own:
  /// the host lets the start that took the Sign in click open its provider page once
  /// (AgentPaneSignInPage.swift). Any later open spends its own click's gesture.
  open(url: string): void;
  /// Opens Claude's automatic page (``LoginStart/autoUrl``) in a Chromium tab whose localhost is the
  /// chat's machine, in the person's own browser store (their claude.com sign-in stays): the approve's
  /// redirect reaches Claude's listener there, cmux carrying only the bytes. Like ``open`` it may
  /// spend the Sign in click's page credit. False when the host cannot (a WebKit default, a machine
  /// without remote localhost, an older host): the card then opens ``LoginStart/url`` for a paste.
  openOnMachine(url: string): Promise<boolean>;
  /// Finishes the login (Claude's pasted code; Codex waits for the approval, and so does Claude with
  /// no code after an automatic page). True when signed in.
  finish(loginId: string, code?: string): Promise<boolean>;
  /// Saves an API key for the agent on the machine. True when saved.
  apiKey(key: string): Promise<boolean>;
  /// Stops a login the card started.
  cancel(loginId: string): void;
  /// Reserves the current click's gesture for one resend of the failed prompt. Call it inside the
  /// click handler; the promise holds the ticket (undefined when the host gave none).
  reserve(): Promise<ResendTicket | undefined>;
  /// Sends the failed prompt again under `ticket`; does nothing without one, or once `wanted`
  /// says the card that asked has gone (checked again after the prompt's attachments load).
  resend(rowId: string, prompt: string, ticket: ResendTicket | undefined, wanted?: () => boolean): Promise<void>;
};

export type ResendTicket = { promptId: string; ticket: string };

/// A failure the card can word.
export class LoginStepError extends Error {
  constructor(readonly failure: LoginFailure) {
    super(failure);
  }
}

/// What ``cloudAgentLogin`` and ``localApiKeyLogin`` take.
type LoginOptions = {
  connected: boolean;
  machineID: string | undefined;
  sessionId: string | undefined;
  harness: string | undefined;
  supported: boolean;
  gesture: (intent: Record<string, unknown>) => Promise<string | undefined>;
  openURL: (url: string) => void;
  /// The host's machine-bound open (``CloudSignIn/openOnMachine``); true when it opened.
  openOnMachine?: (url: string) => Promise<boolean>;
  isCurrent: (sessionId: string) => boolean;
  currentClient: () => LoginClient | undefined;
};

/// The sign-in a Cloud chat's sign-in failure offers, or undefined where there is none: a chat
/// not connected, not on a Cloud machine, not Claude or Codex, or on an acpmux that does not
/// advertise `agent_login`.
export function cloudAgentLogin(options: LoginOptions): CloudSignIn | undefined {
  return options.machineID ? agentLogin(options) : undefined;
}

/// Use an API key for a chat on this Mac whose built-in Claude Code or Codex is not signed in (Leo
/// 2026-10-26: "if user picks a model they don't have api key, we offer them to add credits or add
/// their own api key"). acpmux saves the key where the agent's own CLI reads it (Claude's
/// `settings.json` `env.ANTHROPIC_API_KEY`, `codex login --with-api-key`) and restarts the chat on it.
/// Only the built-in `claude` and `codex` harnesses: a route (`claude-cr`, `claude-sr`) sets its own
/// key and endpoint, which a saved key would never reach. Undefined for a Cloud chat (its card is
/// ``cloudAgentLogin``'s).
export function localApiKeyLogin(options: LoginOptions): CloudSignIn | undefined {
  const harness = options.harness?.split("/").pop();
  if (options.machineID || (harness !== "claude" && harness !== "codex")) return undefined;
  return agentLogin(options);
}

/// The agent's own login on the chat's machine, or undefined for a chat not connected, not Claude or
/// Codex, or on an acpmux that does not advertise `agent_login`.
function agentLogin(options: LoginOptions): CloudSignIn | undefined {
  const { connected, sessionId, harness, supported, gesture, openURL, openOnMachine, isCurrent, currentClient } =
    options;
  const agent = agentKey(harness?.split("/").pop());
  if (!connected || !sessionId || !supported || (agent !== "claude" && agent !== "codex")) return undefined;
  const client = () => {
    const current = currentClient();
    if (!current || !isCurrent(sessionId)) throw new LoginStepError("failed");
    return current;
  };
  const step = async <T>(run: () => Promise<T>): Promise<T> => {
    try {
      return await run();
    } catch (error) {
      if (error instanceof LoginStepError) throw error;
      throw new LoginStepError(loginFailure(error));
    }
  };
  return {
    agent,
    start: () =>
      step(async () => {
        // Every call names the chat, so it runs on the chat's machine (acpmux forwards it there).
        const reply = await client().agentLoginStart(agent, sessionId);
        const started = startOf(reply);
        if (!started) {
          // A page this Mac will not open: stop the login acpmux started, so it holds nothing.
          const loginId = (reply as { loginId?: unknown } | undefined)?.loginId;
          if (typeof loginId === "string" && loginId)
            void currentClient()
              ?.agentLoginCancel(loginId, sessionId)
              .catch(() => undefined);
          throw new LoginStepError("failed");
        }
        return started;
      }),
    open: (url) => {
      const safe = signInURL(url);
      if (safe) openURL(safe);
    },
    openOnMachine: async (url) => {
      const auto = autoSignIn(url);
      if (!auto || !openOnMachine) return false;
      return openOnMachine(auto.url).catch(() => false);
    },
    finish: (loginId, code) =>
      step(async () => {
        const reply = (await client().agentLoginFinish(loginId, sessionId, code)) as { signedIn?: unknown } | undefined;
        return reply?.signedIn === true;
      }),
    apiKey: (key) =>
      step(async () => {
        const reply = (await client().agentLoginApiKey(agent, sessionId, key)) as { saved?: unknown } | undefined;
        return reply?.saved === true;
      }),
    cancel: (loginId) => {
      void currentClient()
        ?.agentLoginCancel(loginId, sessionId)
        .catch(() => undefined);
    },
    reserve: () => {
      const promptId = crypto.randomUUID();
      return gesture({ method: "session/prompt", params: { promptId } }).then(
        (ticket) => (ticket ? { promptId, ticket } : undefined),
        () => undefined,
      );
    },
    resend: async (rowId, prompt, ticket, wanted = () => true) => {
      // Never a send without the person's click (the host would refuse it anyway).
      if (!ticket) return;
      const sender = currentClient();
      if (!sender || !isCurrent(sessionId) || !wanted()) return;
      const draft = await sender.resendPrompt(rowId, prompt);
      if (!wanted() || !isCurrent(sessionId) || currentClient() !== sender) return;
      await sender.send(draft.input, draft.attachments, ticket.promptId, undefined, ticket.ticket);
    },
  };
}
