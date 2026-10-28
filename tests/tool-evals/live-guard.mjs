// What an eval's agent may not reach on the Mac that runs it: the person's browsers and
// their cmux app. A model that runs `open <url>` (the sign-in-link-in-cmux case asks for
// exactly that) must fail inside the sample, not open a tab in the default browser or in
// the person's cmux (2026-10-28: example.com/device?code=ABCD-1234 opened 11 times in Helium).
import { homedir } from "node:os";

/**
 * SBPL lines for every eval sandbox profile. Empty: nothing guards the live machine yet.
 */
export function liveMachineGuards(home = homedir()) {
  void home;
  return [];
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
