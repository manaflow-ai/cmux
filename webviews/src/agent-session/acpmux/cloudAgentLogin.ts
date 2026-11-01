import { agentKey } from "../shared/agentKey";
import type { AcpmuxDirectClient } from "./direct";

// A Cloud chat's own sign-in (Leo 2026-11-01, on the one-click sign-in: "yes those are important"):
// a turn that failed because the agent on the user's Cloud machine is not signed in runs that
// agent's own login ON the machine (acpmux `_acpmux/agent_login/*`), never a copy of this Mac's
// login. The card (CloudSignIn.tsx) drives it; this module is its wire and its rules.

/// The harnesses whose login acpmux runs on the machine.
export type LoginAgent = "claude" | "codex";

/// `_acpmux/agent_login/start`'s answer: the page to open, Codex's device code, whether the page
/// gives a code to paste back (Claude), and when the login lapses.
export type LoginStart = {
  loginId: string;
  url: string;
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
  return {
    loginId: value.loginId,
    url,
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
  /// Opens the sign-in page as a link click in this pane does (spends the click's gesture, so only
  /// from its own click: the Sign in click's gesture goes to the start).
  open(url: string): void;
  /// Finishes the login (Claude's pasted code; Codex waits for the approval). True when signed in.
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

/// The sign-in a Cloud chat's sign-in failure offers, or undefined where there is none: a chat
/// not connected, not on a Cloud machine, not Claude or Codex, or on an acpmux that does not
/// advertise `agent_login`.
export function cloudAgentLogin(options: {
  connected: boolean;
  machineID: string | undefined;
  sessionId: string | undefined;
  harness: string | undefined;
  supported: boolean;
  gesture: (intent: Record<string, unknown>) => Promise<string | undefined>;
  openURL: (url: string) => void;
  isCurrent: (sessionId: string) => boolean;
  currentClient: () => LoginClient | undefined;
}): CloudSignIn | undefined {
  const { connected, machineID, sessionId, harness, supported, gesture, openURL, isCurrent, currentClient } = options;
  const agent = agentKey(harness?.split("/").pop());
  if (!connected || !machineID || !sessionId || !supported || (agent !== "claude" && agent !== "codex"))
    return undefined;
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
