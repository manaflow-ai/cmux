import { CLOUD_SIGN_IN_ANSWERS, type CloudSignInWait } from "./cloudSignIn";
import type { CloudStartAnswer } from "./cloudRun";

/// Cloud first use (cmux-tui/docs/model-connections.md, "Cloud first use"): the host refused a Cloud
/// start with `cloud_setup_required` because no connection serves the picker's model (CloudSetup.swift).
/// The chat shows the Set up Cloud card (conversation/CloudSetupCard.tsx) naming that model; each button
/// is one of Settings > Models' ways in (`cloud.setUp {key, action, family}`, AgentPaneCloudStart.swift
/// `setUpCloud`), and the start goes again by itself once a connection serving the family appears, on
/// the click the host kept (`cloud.startChat {..., signedIn: true}`), with no retyping.

/// The families a Cloud chat runs (CloudSetup.families).
export type CloudSetupFamily = "claude" | "codex";

/// What the card names: the picker's agent family and its model id, when the host said one.
export type CloudSetupNeed = { family: CloudSetupFamily; model?: string };

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
  const raw = (details && typeof details === "object" ? details : {}) as { family?: unknown; model?: unknown };
  if (raw.family !== "claude" && raw.family !== "codex") return undefined;
  const model = typeof raw.model === "string" && raw.model.trim() ? raw.model.trim().slice(0, 128) : undefined;
  return { family: raw.family, ...(model ? { model } : {}) };
}

/// The card's buttons for `need`, in order: the family's own subscription first, then the other's,
/// then a key and Settings (Capy's Models page: subscriptions, then API keys).
export function cloudSetupActions(need: CloudSetupNeed): CloudSetupAction[] {
  return need.family === "codex"
    ? ["connectChatGPT", "setUpClaude", "addKey", "openSettings"]
    : ["setUpClaude", "connectChatGPT", "addKey", "openSettings"];
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
  limitMs = CLOUD_SETUP_LIMIT_MS,
): CloudSignInWait {
  let finish!: (end: "signedIn" | CloudStartAnswer) => void;
  const ended = new Promise<"signedIn" | CloudStartAnswer>((resolve) => {
    finish = resolve;
  });
  let over = false;
  // Not set up yet: the card again, naming the same model.
  const notReady: CloudStartAnswer = { ok: false, code: CLOUD_SETUP_REQUIRED, details: need };
  const end = (value: "signedIn" | CloudStartAnswer, cancel = false) => {
    if (over) return;
    over = true;
    clearTimeout(deadline);
    // The host's wait ends with the page's: `cloud.signInCancel` cancels it and keeps no click.
    if (cancel) void call("cloud.signInCancel", {}).catch(() => undefined);
    finish(value);
  };
  const deadline = setTimeout(() => end(notReady, true), limitMs);
  call("cloud.setUp", { key, action, family: need.family }).then(
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
