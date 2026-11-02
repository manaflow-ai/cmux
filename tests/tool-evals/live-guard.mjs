// What an eval's agent may not reach on the Mac that runs it: the person's browsers and
// their cmux app. A model that runs `open <url>` (the sign-in-link-in-cmux case asks for
// exactly that) must fail inside the sample, not open a tab in the default browser or in
// the person's cmux (2026-10-28: example.com/device?code=ABCD-1234 opened 11 times in Helium).
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

/**
 * SBPL lines for every eval sandbox profile:
 * - no `/usr/bin/open` or `osascript` (what `open`, Node's `open` package, Go's pkg/browser
 *   and Python's webbrowser run) and no LaunchServices open;
 * - no connection to the person's cmux app sockets (`~/.local/state/cmux`, `/tmp/cmux*.sock`,
 *   and `$TMPDIR/cmux…/`, where the app socket the CLI finds, `cmux-tui-<uid>/cmux-app…`,
 *   lives), which the `cmux` CLI or a cmux `open`/`cmux-open-url` shim on PATH would reach.
 * A sample's own sockets live under `/tmp/cte` and stay reachable.
 */
export function liveMachineGuards(home = homedir()) {
  const state = join(realpathOr(home), ".local/state/cmux");
  return [
    '(deny process-exec (literal "/usr/bin/open") (literal "/usr/bin/osascript"))',
    "(deny lsopen)",
    `(deny network-outbound (remote unix-socket (subpath ${JSON.stringify(state)})))`,
    '(deny network-outbound (remote unix-socket (regex #"^/private/tmp/cmux[^/]*\\.sock$")))',
    '(deny network-outbound (remote unix-socket (regex #"^/private/var/folders/[^/]+/[^/]+/T/cmux[^/]*/")))',
  ];
}

// The sandbox matches resolved paths (/tmp is /private/tmp): resolve the longest existing prefix.
function realpathOr(path) {
  try { return realpathSync(path); } catch { return path === dirname(path) ? path : join(realpathOr(dirname(path)), basename(path)); }
}

/** The profile an agent harness (Claude Code, Codex) runs under. */
export function agentProfile(home = homedir()) {
  return ["(version 1)", "(allow default)", ...liveMachineGuards(home), ""].join("\n");
}

/**
 * The profile of the API runner's Bash tool: every cmux socket but the sample's own is
 * blocked, and writes stay in the sample's directories.
 */
export function shellProfile({ sessionName, work, dir, home = homedir() }) {
  return [
    "(version 1)",
    "(allow default)",
    '(deny network-outbound (remote unix-socket (path-regex #"cmux")))',
    `(allow network-outbound (remote unix-socket (path-regex #"/${sessionName.replace(/[.-]/g, "\\$&")}\\.sock$")))`,
    "(deny file-write* (subpath \"/Users\"))",
    `(allow file-write* (subpath ${JSON.stringify(work)}) (subpath ${JSON.stringify(dir)}))`,
    ...liveMachineGuards(home),
    "",
  ].join("\n");
}
