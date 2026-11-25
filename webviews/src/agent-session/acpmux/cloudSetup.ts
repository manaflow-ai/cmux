import { CLOUD_CHATGPT_SIGN_IN_READY } from "../shared/cloudModelConnections";
import { CLOUD_SIGN_IN_ANSWERS, type CloudSignInWait } from "./cloudSignIn";
import type { CloudStartAnswer } from "./cloudRun";

/// Cloud first use (cmux-tui/docs/model-connections.md, "Cloud first use"): the host refused a Cloud
/// start with `cloud_setup_required` because no connection serves the picker's model (CloudSetup.swift).
/// The card opens Settings > Cloud > Cloud models for that family (`cloud.setUp {key, action, family}`). Once
/// the host finds a connection, the start goes again on the click it kept, with no retyping.

const setupNames = {
  claude: "Claude",
  codex: "Codex",
  gemini: "Gemini",
  grok: "Grok",
  "github-copilot": "GitHub Copilot",
  openrouter: "OpenRouter",
} as const;

export function cloudSetupName(family: string): string {
  return Object.hasOwn(setupNames, family) ? setupNames[family as keyof typeof setupNames] : family;
}

function setupFamily(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length <= 128 &&
    value.split("/").every((part) => part.length > 0 && !/[^a-zA-Z0-9._:@-]/.test(part))
  );
}

/// What the card names: the picker's agent family and its model id, when the host said one.
export type CloudSetupNeed = { family: string; model?: string; machine?: string; timedOut?: true };

/// The card's ways in, as `cloud.setUp {action}` names them (CloudSetup.Action).
export const CLOUD_SETUP_ACTIONS = ["connectChatGPT", "setUpClaude", "addKey", "openSettings"] as const;
export type CloudSetupAction = (typeof CLOUD_SETUP_ACTIONS)[number];

/// The host's refusal code for a start nothing serves.
export const CLOUD_SETUP_REQUIRED = "cloud_setup_required";

/// How long a set up waits for a connection before the card offers its buttons again: a browser
/// sign-in's deadline (`CLOUD_SIGN_IN_LIMIT_MS`) doubled, for a key pasted in Settings.
export const CLOUD_SETUP_LIMIT_MS = 600_000;

/// The refusal's details (`{family, model}`) as the card's need; undefined for anything else.
export function readCloudSetupNeed(details: unknown): CloudSetupNeed | undefined {
  const raw = (details && typeof details === "object" ? details : {}) as {
    family?: unknown;
    model?: unknown;
    machine?: unknown;
    timedOut?: unknown;
  };
  if (!setupFamily(raw.family)) return undefined;
  const model = typeof raw.model === "string" && raw.model.trim() ? raw.model.trim().slice(0, 128) : undefined;
  const machine =
    typeof raw.machine === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(raw.machine) ? raw.machine : undefined;
  return {
    family: raw.family,
    ...(model ? { model } : {}),
    ...(machine ? { machine } : {}),
    ...(raw.timedOut === true ? { timedOut: true } : {}),
  };
}

/// The card's single way in, using the same provider as the picker's Connect.
export function cloudSetupAction(need: CloudSetupNeed, chatGPTReady = CLOUD_CHATGPT_SIGN_IN_READY): CloudSetupAction {
  if (need.family === "claude") return "setUpClaude";
  if (need.family === "codex") return chatGPTReady ? "connectChatGPT" : "addKey";
  return "openSettings";
}

/// A failed send owns Connect for its family, including while its setup is already pending.
export function connectHeldCloudSend(
  family: string,
  need: CloudSetupNeed | undefined,
  waiting: boolean,
  setUp: (action: CloudSetupAction) => void,
): boolean {
  if (!need || need.family !== family) return false;
  if (!waiting) setUp(cloudSetupAction(need));
  return true;
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// Runs `action` for start `key` on the card's click and waits for a connection serving `need`'s family,
/// ending at the first of: the host's answer, the page's withdraw, or `limitMs`. Shaped as a sign-in's
/// wait (cloudSignIn.ts), so the start goes again the same way (`startAfterSignIn`).
export function waitForCloudSetUp(
  call: Native,
  key: string,
  action: CloudSetupAction,
  need: CloudSetupNeed,
  schedule = (run: () => void) => {
    const deadline = setTimeout(run, CLOUD_SETUP_LIMIT_MS);
    return () => clearTimeout(deadline);
  },
  machine?: string,
  environment?: string,
): CloudSignInWait {
  let finish!: (end: "signedIn" | CloudStartAnswer) => void;
  const ended = new Promise<"signedIn" | CloudStartAnswer>((resolve) => {
    finish = resolve;
  });
  let over = false;
  // Not set up yet: the card again, naming the same model.
  const { timedOut: _timedOut, ...details } = need;
  const notReady: CloudStartAnswer = { ok: false, code: CLOUD_SETUP_REQUIRED, details };
  const end = (value: "signedIn" | CloudStartAnswer, cancel = false) => {
    if (over) return;
    over = true;
    cancelDeadline();
    // The host's wait ends with the page's: `cloud.signInCancel` cancels it and keeps no click.
    if (cancel) void call("cloud.signInCancel", {}).catch(() => undefined);
    finish(value);
  };
  const cancelDeadline = schedule(() => end({ ...notReady, details: { ...details, timedOut: true } }, true));
  const target = machine ?? need.machine;
  call("cloud.setUp", {
    key,
    action,
    family: need.family,
    ...(target ? { machine: target } : {}),
    ...(environment ? { environment } : {}),
  }).then(
    () => end("signedIn"),
    (error: unknown) => {
      const code = (error as { code?: unknown } | null)?.code;
      end(code === "cloud_sign_in_cancelled" ? CLOUD_SIGN_IN_ANSWERS.withdrawn : notReady);
    },
  );
  const withdraw = () => {
    if (over) void call("cloud.signInCancel", {}).catch(() => undefined);
    else end(CLOUD_SIGN_IN_ANSWERS.withdrawn, true);
  };
  return { ended, withdraw };
}

/// Set up Cloud's button: `pick` is in `slot` only while `retry` runs. The resend it starts reads the
/// pick then and there (App.tsx `beginCloudSend`); a retry that sent nothing (one already out or
/// resumed, an edited prompt, no start to resend) leaves no pick for a later plain Sign in to take.
export function retryWithSetUpPick<Pick>(
  slot: { current: Pick | undefined },
  pick: Pick,
  retry: () => Promise<boolean>,
): Promise<boolean> {
  slot.current = pick;
  try {
    return retry();
  } finally {
    slot.current = undefined;
  }
}
