import type { CloudStartAnswer } from "./cloudRun";

/// A Cloud start's inline sign-in. The page owns it: the card's waiting state, the wait's deadline
/// and its cancel live here. The app only signs the account in on the card's click and keeps that
/// click for the start's one send again (`cloud.signIn {key}`, AgentPaneCloudStart.swift
/// `signInToCloud`); the start then goes as `cloud.startChat {..., signedIn: true}`.

/// How long a sign-in waits on the browser before the card offers Sign in again: the auth runtime's
/// deadline for an interactive sign-in (`AuthTimeouts.default.interactiveFlow`, 300 s).
export const CLOUD_SIGN_IN_LIMIT_MS = 300_000;

/// The card's answers for a sign-in that did not sign in; `not_signed_in` offers Sign in again.
export const CLOUD_SIGN_IN_ANSWERS = {
  notSignedIn: { ok: false, code: "not_signed_in", message: "Sign in to continue" },
  expired: { ok: false, code: "not_signed_in", message: "Sign-in timed out. Sign in again to continue." },
  withdrawn: { ok: false, code: "cloud_sign_in_cancelled" },
} as const satisfies Record<string, CloudStartAnswer>;

export type CloudSignInWait = {
  /// `signedIn`: the app kept the click, so the start may go again. Otherwise the start's answer.
  ended: Promise<"signedIn" | CloudStartAnswer>;
  /// The page left Cloud (another mode, chat or tab): the wait ends now and the app keeps no click.
  /// The browser sign-in still finishes; only its start is gone.
  withdraw: () => void;
};

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The host's refusal as the start's answer: its code and words, or not signed in.
function refusal(error: unknown): CloudStartAnswer {
  const { code, message, userMessage } = (error ?? {}) as { code?: unknown; message?: unknown; userMessage?: unknown };
  if (typeof code !== "string" || code === "not_signed_in") return CLOUD_SIGN_IN_ANSWERS.notSignedIn;
  const words = typeof userMessage === "string" ? userMessage : typeof message === "string" ? message : undefined;
  return { ok: false, code, ...(words ? { message: words } : {}) };
}

/// Signs in for start `key` on the card's click, ending at the first of: the app's answer, the
/// page's withdraw, or `limitMs`. Past the limit the app's browser sign-in is cancelled too
/// (`cloud.signInCancel {expired: true}`), so Sign in again opens a fresh one.
export function waitForCloudSignIn(call: Native, key: string, limitMs = CLOUD_SIGN_IN_LIMIT_MS): CloudSignInWait {
  let finish!: (end: "signedIn" | CloudStartAnswer) => void;
  const ended = new Promise<"signedIn" | CloudStartAnswer>((resolve) => {
    finish = resolve;
  });
  let over = false;
  const end = (value: "signedIn" | CloudStartAnswer, cancel?: { expired: boolean }) => {
    if (over) return;
    over = true;
    clearTimeout(deadline);
    if (cancel) void call("cloud.signInCancel", cancel.expired ? { expired: true } : {}).catch(() => undefined);
    finish(value);
  };
  // Its stop: the app answers, the page withdraws, or this deadline passes; each clears it.
  const deadline = setTimeout(() => end(CLOUD_SIGN_IN_ANSWERS.expired, { expired: true }), limitMs);
  call("cloud.signIn", { key }).then(
    () => end("signedIn"),
    (error: unknown) => end(refusal(error)),
  );
  const withdraw = () => {
    // Also after the app answered signed in: its cancel drops the click it kept for the start.
    if (over) void call("cloud.signInCancel", {}).catch(() => undefined);
    else end(CLOUD_SIGN_IN_ANSWERS.withdrawn, { expired: false });
  };
  return { ended, withdraw };
}

/// The start after its sign-in: it goes again (`again`, on the app's kept click) only when the sign-in
/// signed in and the page still waits for it (`stillWaiting`); otherwise the sign-in's answer.
export function startAfterSignIn(
  wait: CloudSignInWait,
  stillWaiting: () => boolean,
  again: () => Promise<CloudStartAnswer> | undefined,
): Promise<CloudStartAnswer> {
  return wait.ended.then((end) => {
    if (end !== "signedIn") return end;
    if (!stillWaiting()) return CLOUD_SIGN_IN_ANSWERS.withdrawn;
    return again() ?? CLOUD_SIGN_IN_ANSWERS.withdrawn;
  });
}
