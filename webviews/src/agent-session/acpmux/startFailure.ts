import { failureCopy, failureKind } from "./failureCopy";
import type { Translate } from "./i18n";
import { INSTALL_COMMANDS } from "./harnesses/harnessRows";
import { startRefusalAction } from "./startRefusal";

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
  switching: { harness: string; name: string; error?: string; code?: string },
): StartFailureView {
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
