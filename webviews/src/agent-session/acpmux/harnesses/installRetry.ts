// An install that survives a dropped network (first-run finding 6: the network dropped for 20 s
// during the Claude Code install; the row said "Failed: Try running with --force to override
// checks", stayed failed after the network came back, and had no Retry).
//
// The host runs a command only on the person's click (`shell.run`'s gesture rule), so the page
// cannot start a second install on its own when the network returns. The retry lives inside the
// one command the click started: `withNetworkRetry` runs the installer, and when it fails while
// the network is down (or with a network error in its output) it prints `OFFLINE_MARK`, waits
// until the installer's server answers again, prints `RETRY_MARK` and runs it again, at most
// `RUNS` times. A failure with the network up is the installer's own: it ends at once with its
// exit code. The rows turn those lines and the last line of a failure into plain words
// (`installProgress`, `installFailure`); Retry on a failed row is the person's own click.
import type { Translate } from "../i18n";

/// The line the wrapped command prints when it waits for the network.
export const OFFLINE_MARK = "cmux-install: waiting for the network";
/// The line it prints when the network is back and the install runs again.
export const RETRY_MARK = "cmux-install: running the install again";

/// How many times an install runs at most (the first run and two after a dropped network).
const RUNS = 3;

/// Installer output that means the network failed it: curl's and npm's connection errors, Node's
/// error codes, and the installers' own "download failed". Matched case-insensitively, as an ERE in
/// the shell and as a RegExp here; no quotes, `$` or backslashes, so it sits in both as typed.
const NETWORK_ERRORS =
  "could not resolve|resolve host|network|timed out|connection (refused|reset|closed)|failed to connect|recv failure|ssl_error|econnreset|econnrefused|etimedout|enotfound|eai_again|getaddrinfo|fetch failed|unable to connect|download failed|unreachable";

const networkError = new RegExp(NETWORK_ERRORS, "i");

/// Advice written for a terminal user (a flag to pass, a command to run again).
const commandLineAdvice = /(^|\s)--?[a-z][\w-]*|\btry running\b|\brun (it )?again with\b/i;

export type NetworkRetry = {
  /// A shell command that exits 0 while the installer's server is reachable (default: a 5-second
  /// request to `probeUrl`).
  online?: string;
  /// The URL the default check asks; any HTTP answer counts as online.
  probeUrl?: string;
  /// How often the wait checks the network.
  pollSeconds?: number;
  /// How long the wait lasts before the install fails for good (the row then offers Retry).
  waitSeconds?: number;
};

/// `script` (bash, no single quotes) as one command that runs again by itself after a network drop.
export function withNetworkRetry(
  script: string,
  { online, probeUrl, pollSeconds = 3, waitSeconds = 15 * 60 }: NetworkRetry = {},
): string {
  const check = online ?? (probeUrl ? `curl -sS --max-time 5 -o /dev/null ${probeUrl}` : "true");
  for (const part of [script, check])
    // l10n-allow: a caller's bug, never shown.
    // l10n-allow: a caller's bug (a script with a quote), never drawn
    if (part.includes("'")) throw new Error("an install script must hold no single quote");
  const polls = Math.max(1, Math.ceil(waitSeconds / pollSeconds));
  const wrapper = [
    // The system tools the wrapper uses, after whatever the login shell put first.
    `PATH="$PATH:/usr/bin:/bin"`,
    `online() { ${check} ; } >/dev/null 2>&1`,
    `log=$(mktemp "\${TMPDIR:-/tmp}/cmux-install.XXXXXX") || exit 1`,
    `trap "rm -f \\"$log\\"" EXIT`,
    "run=1",
    "while :; do",
    `  { ${script} ; } 2>&1 | tee "$log"`,
    "  code=${PIPESTATUS[0]}",
    `  [ "$code" -eq 0 ] && exit 0`,
    "  dropped=0",
    `  grep -qiE "${NETWORK_ERRORS}" "$log" && dropped=1`,
    "  online || dropped=1",
    `  if [ "$dropped" -eq 0 ] || [ "$run" -ge ${RUNS} ]; then exit "$code"; fi`,
    "  if ! online; then",
    `    echo "${OFFLINE_MARK}"`,
    "    polls=0",
    "    until online; do",
    `      [ "$polls" -ge ${polls} ] && exit "$code"`,
    `      sleep ${pollSeconds}`,
    "      polls=$((polls + 1))",
    "    done",
    "  fi",
    `  echo "${RETRY_MARK}"`,
    "  run=$((run + 1))",
    "done",
  ].join("\n");
  // l10n-allow: a shell command line, not text.
  // l10n-allow: a shell command, not text a person reads
  return `/bin/bash -o pipefail -c '${wrapper}'`;
}

/// What an installing row shows for the command's last output line.
export function installProgress(line: string, t: Translate): string {
  if (line === OFFLINE_MARK) return t("harnesses.install.waitingNetwork");
  if (line === RETRY_MARK) return t("harnesses.install.retrying");
  return line;
}

/// The plain words for an install that failed, from its last output line: a dropped network, an
/// installer's terminal advice (never shown: "--force"), or the line itself.
export function installFailure(line: string | undefined, t: Translate): string {
  const plain = plainInstallFailure(line, t);
  if (plain) return plain;
  return line ? t("harnesses.commandFailedBecause", { reason: line }) : t("harnesses.commandFailed");
}

/// Plain words for a failed install's last line when it is a dropped network or advice written for
/// a terminal user; nil when the line already says what happened.
export function plainInstallFailure(line: string | undefined, t: Translate): string | undefined {
  if (!line) return undefined;
  if (line === OFFLINE_MARK || line === RETRY_MARK || networkError.test(line))
    return t("harnesses.install.networkDropped");
  if (commandLineAdvice.test(line)) return t("harnesses.install.incomplete");
  return undefined;
}
