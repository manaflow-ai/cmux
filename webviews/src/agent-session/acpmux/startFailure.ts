import { agentName } from "./agents";
import { failureCopy, failureKind } from "./failureCopy";
import { isRawDaemonText, peerLinkFailure, peerLinkLine } from "./hostLine";
import { knownRefusalText, startErrorMessage } from "./transportErrors";
import type { Translate } from "./i18n";
import { INSTALL_COMMANDS } from "./harnesses/harnessRows";
import {
  CMUX_ROUTER_HARNESS,
  HARNESS_MISSING,
  ROUTE_UNAVAILABLE,
  SIGN_IN_REQUIRED,
  startRefusalAction,
} from "./startRefusal";

/// The start-failed card's words (SwitchNotice.tsx): one plain sentence, the agent's raw words for
/// Details, and Install when the agent is not on the machine and cmux knows how to install it
/// (Lawrence, 2026-11-07: "better error messages in the chat ui itself"). A refusal cmux-tui coded
/// with its own way out (startRefusal.ts) is a sentence written for people: it stays the sentence,
/// with no Details. Every other failure is classified as a failed turn is (failureCopy.ts), so
/// "connect ECONNREFUSED" reads "could not reach its server" here as it does in the transcript.
export type StartFailureView = {
  sentence: string;
  /// The raw words, for Details and Copy error; none when the sentence is already them.
  detail?: string;
  /// The command Install runs in a terminal tab.
  install?: string;
  /// The agent is not on the machine: a surface without a terminal (New Tab) still offers Install,
  /// through Agents setup, which installs it and continues the draft.
  notInstalled?: true;
  /// The sentence is only "<agent> couldn't start.": the reason is all in `detail`. A surface with
  /// no Details (the pane's notice row) says the reason in its one line instead.
  unexplained?: true;
};

/// The spawn words for a binary that is not there: the spawn's own `ENOENT` ("spawn claude-agent-acp:
/// No such file or directory"), a shell's "command not found", acpmux's own "is not installed". A
/// missing file or folder the agent names is not a missing agent (`MISSING_FOLDER`).
const NOT_INSTALLED =
  /\bspawn\b[^\n]*(?:\bENOENT\b|no such file or directory)|command not found|executable (?:file )?not found|not found in \$?PATH|\bis not installed\b/i;
const MISSING_FOLDER = /\b(?:cwd|current_dir|working (?:dir|directory|folder)|folder)\b/i;

/// Prose for a person: whole sentences, ending with a period, with none of an error's machinery (a
/// `word:` prefix, an all-caps errno or code, an os error, a hex value, a call, a path, a URL, a frame).
const MACHINERY =
  /:\s|\b[A-Z]{2,}[A-Z_0-9]*\b|\b[Oo]s error\b|\berrno\b|0x[0-9a-fA-F]+|[\w-]+\.[\w-]+\(|\/\w+\/|https?:\/\/|\bat \S+:\d+/;
function writtenForPeople(text: string): boolean {
  return /[.!?]$/.test(text) && !text.includes("\n") && text.split(" ").length >= 4 && !MACHINERY.test(text);
}

/// The codes of a start that never reached the agent because the page's line to acpmux was down or
/// went down: the pane host found no daemon (`transport.connect_failed`, `transport.no_connection`),
/// closed the socket (`transport.closed`, an overflow), or the page had no open connection
/// (`native.not_connected`). acpmux restarting reads this way; the agent itself was never asked.
/// A start whose connection to acpmux dropped before it answered (direct.ts `rejectPending`, an
/// `interrupted` failure): harnessSwitch.ts gives it this code, since its own (`native.timed_out`) is
/// also a deadline's.
export const START_CONNECTION_LOST = "start.connection_lost";

const SERVICE_UNREACHABLE = new Set([
  START_CONNECTION_LOST,
  "native.not_connected",
  "transport.connect_failed",
  "transport.no_connection",
  "transport.closed",
  "transport.stale_connection",
  "transport.inbound_overflow",
  "transport.outbound_overflow",
]);

/// A start that failed only because the page's line to acpmux was down or went down: nothing the
/// person can do about it, so the switch starts again by itself on the next connection (or on this
/// one, once it answers) instead of failing with "Try again" (Leo, 2026-11-12, after a reboot: "if
/// we do the recovery needs to be a lot better and it shouldn't talk so much bullshit", and on a
/// Try again line: "try what? no, it should just automatically do stuff").
export function isConnectionLoss(error: unknown): boolean {
  const code = startFailureCode(error);
  return code !== undefined && SERVICE_UNREACHABLE.has(code);
}

/// Codes whose card already says all it needs (startFailureSentence's own views).
const CODED = new Set([SIGN_IN_REQUIRED, HARNESS_MISSING, ROUTE_UNAVAILABLE]);

type StartFailure = {
  harness: string;
  name: string;
  error?: string;
  code?: string;
  signInExpired?: true;
  /// What actually failed, for Details and the log (`startFailureCause`).
  cause?: string;
};

/// The card's words, with what actually failed (`cause`) under Details whenever the sentence does
/// not already say all of it: a start failure never ends at a sentence with nothing behind it (#44964).
export function startFailureView(t: Translate, switching: StartFailure): StartFailureView {
  const view = startFailureSentence(t, switching);
  const cause = switching.cause?.trim();
  // A refusal coded with its own way out (startRefusal.ts: sign-in, a missing agent, a route, a
  // folder) is written for people and keeps the Details its view chose; the log has its cause.
  if (startRefusalAction(switching.code) || CODED.has(switching.code ?? "")) return view;
  if (view.detail || !cause || view.sentence.includes(cause)) return view;
  return { ...view, detail: cause };
}

/// What failed at a start, in one line for Details, Copy error and the log: the failure's own message,
/// then the fields that tell failures apart (the refusal's code, acpmux's reason and kind, the method
/// the pane host refused, the host's or acpmux's own detail such as the param it refused). None
/// without anything beyond an empty message.
export function startFailureCause(error: unknown): string | undefined {
  const typed = (typeof error === "object" && error !== null ? error : {}) as Record<string, unknown>;
  // A start HarnessSwitch already failed hands its prompts back with the cause it found.
  if (typeof typed.startCause === "string" && typed.startCause) return typed.startCause;
  const message = error instanceof Error ? error.message : typeof error === "string" ? error : "";
  const field = (key: string) => (typeof typed[key] === "string" && typed[key] ? (typed[key] as string) : undefined);
  const code = typeof typed.code === "number" ? String(typed.code) : field("code");
  const facts = [
    code && `code ${code}`,
    field("reason") && field("reason") !== code && `reason ${field("reason")}`,
    field("errorKind") && `kind ${field("errorKind")}`,
    field("method") && `method ${field("method")}`,
  ].filter(Boolean);
  const detail = field("detail");
  const line = [message.trim(), detail && detail !== message.trim() ? detail : undefined].filter(Boolean).join(": ");
  const text = [line, facts.length ? `(${facts.join(", ")})` : ""].filter(Boolean).join(" ");
  return text || undefined;
}

/// A failed start's code for the card: the failure's own, except a connection that dropped while
/// acpmux started the agent (direct.ts `rejectPending`, `interrupted`), whose `native.timed_out` is
/// also a deadline's, so it reads by its own (`START_CONNECTION_LOST`).
export function startFailureCode(error: unknown): string | undefined {
  const typed = error as { code?: unknown; interrupted?: unknown; startCode?: unknown } | undefined;
  // A start HarnessSwitch already failed hands its prompts back with the code it read.
  if (typeof typed?.startCode === "string") return typed.startCode;
  if (typed?.interrupted === true) return START_CONNECTION_LOST;
  return typeof typed?.code === "string" ? typed.code : undefined;
}

/// Writes a failed start to the app's log (the agent pane's `console.error` reaches the unified log,
/// ConsoleErrorCapture), with the chat it was starting: `none` before acpmux made one.
export function logStartFailure(harness: string, sessionId: string | undefined, cause: string | undefined): void {
  console.error(`agent pane: couldn't start ${harness} session=${sessionId ?? "none"}: ${cause ?? "no error"}`);
}

/// The codes of a start that never reached the agent because acpmux was away or went away: the
/// pane's host line already says the agent service is away, so a sessionless send's start says
/// nothing more there (sendFailure.ts `host-away`, Leo 2026-11-12); the log still has it.
const HOST_AWAY = new Set(["native.timed_out", ...SERVICE_UNREACHABLE]);

/// Whether a failed start clears by itself when asked again: it never reached the agent because the
/// page's line to acpmux was down (`HOST_AWAY`), so starting again is the only answer and is no
/// one's decision. The pane starts it again on its own (App.tsx, autoRetry.ts `useAutoRetry`) and
/// draws no card for it, only "Still trying to start <agent>…" once it has lasted (Leo, 2026-11-22:
/// "vacuous decisions like that should be just done").
export function startFailureClearsByItself(code: string | undefined): boolean {
  return code !== undefined && HOST_AWAY.has(code);
}

/// A sessionless chat's start that another chat's selection (or the page closing) overtook
/// (direct.ts `ensureSession`): no failure of the chat now shown.
export function isStartSuperseded(error: unknown): boolean {
  return (error as { superseded?: unknown } | null)?.superseded === true;
}

/// Words an agent or acpmux wrote for people, safe as a notice's reason: one short line, no code,
/// path, stack or protocol text (`hostLine.ts` `isRawDaemonText`, `MACHINERY`). acpmux's own
/// refusals often end without a period ("agent launch is disabled in this build session").
function plainReason(text: string | undefined): string | undefined {
  const words = text?.trim();
  if (!words || words.length > 160 || words.includes("\n") || words.split(" ").length < 4) return undefined;
  return MACHINERY.test(words) || isRawDaemonText(words) ? undefined : words;
}

/// A chat's first send that started its session itself (direct.ts `ensureSession`, no HarnessSwitch)
/// and failed: logs the cause, and returns the line the pane's notice says, or nothing for a start
/// that waited for acpmux (`HOST_AWAY`). Before, that start put the prompt back with no word of why
/// (#44964). The notice row has no Details, so the line carries the reason itself when it is plain
/// words; raw text stays in the log. `harness`: the agent the send started, when the pane knows it.
export function startFailureNotice(t: Translate, harness: string | undefined, error: unknown): string | undefined {
  const cause = startFailureCause(error);
  logStartFailure(harness ?? "agent", undefined, cause);
  const code = startFailureCode(error);
  if (code && HOST_AWAY.has(code)) return undefined;
  // A peer chat whose machine is down says which machine, as its sends do.
  const peer = peerLinkFailure(error);
  if (peer) return peerLinkLine(peer, t);
  const known = knownRefusalText(error, "transport.intentInvalidStart");
  if (!harness) {
    const reason = known ?? plainReason(startErrorMessage(error));
    // retry-prompt-ok: a start that failed for its own reason; Retry starts the agent again.
    return reason ? t("switch.failedUnnamed", { reason }) : t("chat.newFailed");
  }
  const name = agentName(harness);
  const view = startFailureView(t, {
    harness,
    name,
    error: startErrorMessage(error) || t("switch.unknownError"),
    ...(code ? { code } : {}),
    ...(cause ? { cause } : {}),
  });
  if (!view.unexplained) return view.sentence;
  const reason = plainReason(view.detail);
  return reason ? t("switch.failed", { agent: name, reason }) : view.sentence;
}

function startFailureSentence(t: Translate, switching: StartFailure): StartFailureView {
  if (switching.code && SERVICE_UNREACHABLE.has(switching.code))
    // SwitchNotice does not show this one: the pane starts the agent again on its own and says only
    // "Still trying to start…" (startFailureClearsByItself). newtab/StartFailure still shows it.
    return { sentence: t("switch.serviceUnreachable", { agent: switching.name }) };
  if (switching.code === SIGN_IN_REQUIRED) return signInView(t, switching);
  if (switching.code === HARNESS_MISSING) return missingView(t, switching);
  if (switching.code === ROUTE_UNAVAILABLE) return routeView(t, switching);
  // The switch's own stand-in for no words ("unknown error") says nothing worth a Details.
  const words = switching.error?.trim();
  const raw = words && words !== t("switch.unknownError") ? words : undefined;
  if (!raw) return { sentence: t("turn.failure.spawnFailed", { harness: switching.name }) };
  // A refusal coded with its own way out is written for people: it stays the sentence.
  if (startRefusalAction(switching.code))
    return { sentence: t("switch.failed", { agent: switching.name, reason: raw }) };
  const kind = failureKind(raw, { name: switching.name, harness: switching.harness }, switching.code);
  if ((kind === "spawn-failed" || kind === "other") && NOT_INSTALLED.test(raw) && !MISSING_FOLDER.test(raw)) {
    const install = INSTALL_COMMANDS[switching.harness];
    return {
      sentence: t("switch.notInstalled", { agent: switching.name }),
      detail: raw,
      notInstalled: true,
      ...(install ? { install } : {}),
    };
  }
  // A sentence written for people (cmux-tui's "build-box did not start the agent in time. Try
  // again.") is already plain words: it stays the sentence, after the not-installed check above.
  if (writtenForPeople(raw)) return { sentence: t("switch.failed", { agent: switching.name, reason: raw }) };
  // An unknown failure at start is a start that failed, not "had a problem and stopped".
  if (kind === "other") {
    // An unclassified failure in plain words says them: "Claude Code couldn't start." with the
    // reason only under Details told nobody why (#44964). Raw text stays under Details.
    const reason = plainReason(raw);
    if (reason) return { sentence: t("switch.failed", { agent: switching.name, reason }), detail: raw };
    return { sentence: t("turn.failure.spawnFailed", { harness: switching.name }), detail: raw, unexplained: true };
  }
  return {
    sentence: failureCopy(t, raw, { name: switching.name, harness: switching.harness }, switching.code),
    detail: raw,
  };
}

/// A start whose agent is not signed in on the machine (hq#11225): the agent by name, the expired
/// sign-in said as one, and the agent's own words (or the host's) under Details. Sign in is the
/// card's action (startRefusal.ts), so the sentence names only the cause.
function signInView(t: Translate, switching: { name: string; error?: string; signInExpired?: true }): StartFailureView {
  const agent = switching.name.trim();
  const sentence = !agent
    ? t("switch.signInRequiredUnnamed")
    : t(switching.signInExpired ? "switch.signInExpired" : "switch.signInRequired", { agent });
  return withDetail(t, sentence, switching.error);
}

/// The refusal's own words (the host's or the agent's) under Details, unless they say nothing more.
function withDetail(t: Translate, sentence: string, error: string | undefined): StartFailureView {
  const words = error?.trim();
  const detail = words && words !== t("switch.unknownError") && words !== sentence ? words : undefined;
  return detail ? { sentence, detail } : { sentence };
}

/// A start of an agent the machine does not have (`agent_session.harness_missing`, hq#11225): the
/// agent by name, as a spawn that found no CLI reads, with Install where cmux knows its installer
/// (SwitchNotice offers it only for a chat on this Mac).
function missingView(t: Translate, switching: { harness: string; name: string; error?: string }): StartFailureView {
  const agent = switching.name.trim();
  const sentence = agent ? t("switch.notInstalled", { agent }) : t("switch.notInstalledUnnamed");
  const install = INSTALL_COMMANDS[switching.harness];
  return { ...withDetail(t, sentence, switching.error), notInstalled: true, ...(install ? { install } : {}) };
}

/// A start whose model route cannot serve it on the machine (`agent_session.route_unavailable`,
/// hq#11225). The cmux router is named as the router; any other agent by its route. The words hold
/// for as long as the refusal does: it comes only when the route truly cannot serve the start.
function routeView(t: Translate, switching: { harness: string; name: string; error?: string }): StartFailureView {
  const agent = switching.name.trim();
  const sentence =
    switching.harness === CMUX_ROUTER_HARNESS
      ? t("switch.routerUnavailable")
      : agent
        ? t("switch.routeUnavailable", { agent })
        : t("switch.routeUnavailableUnnamed");
  return withDetail(t, sentence, switching.error);
}
