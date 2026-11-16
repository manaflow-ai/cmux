import { failureCopy, failureKind } from "./failureCopy";
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

export function startFailureView(
  t: Translate,
  switching: { harness: string; name: string; error?: string; code?: string; signInExpired?: true },
): StartFailureView {
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
  const sentence =
    kind === "other"
      ? t("turn.failure.spawnFailed", { harness: switching.name })
      : failureCopy(t, raw, { name: switching.name, harness: switching.harness }, switching.code);
  return { sentence, detail: raw };
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
