/**
 * The Chief's approval policy and harness routing, as decisions every brain
 * makes the same way (the shared behavior corpus, `policy` cases; Rust
 * cmux_chief::policy). Each brain applies them its own way: optchat-chief per
 * turn session and per spawned child; the cloud MuxDO brain per turn.
 */

export const REMOTE_AUTO_APPROVE = "remote.autoApprove";
export const ASK = "ask";

/**
 * `remote.autoApprove` from a Chief's settings (`{"remote": {"autoApprove":
 * bool}}`): a remote-origin turn runs with the configured policy instead of
 * `ask`. Default true; a missing or non-bool value is the default.
 */
export function remoteAutoApprove(settings: unknown): boolean {
  const remote = (settings as { remote?: unknown } | null | undefined)?.remote;
  const value = (remote as { autoApprove?: unknown } | null | undefined)?.autoApprove;
  return typeof value === "boolean" ? value : true;
}

/** `ask` when a paired device drives the turn and remote.autoApprove is off; else the configured policy. */
export function turnPolicy(remote: boolean, autoApprove: boolean, configured: string): string {
  return remote && !autoApprove ? ASK : configured;
}

/** The policy floor for a child spawned now: `ask` during an ask turn or while an ask child or subagent is live, unless remote.autoApprove is on. */
export function spawnFloor(autoApprove: boolean, turnAsk: boolean, askChildLive: boolean, askSubagentLive: boolean): string | null {
  if (autoApprove) return null;
  return turnAsk || askChildLive || askSubagentLive ? ASK : null;
}

export const CLAUDE_STDIO = "claude-stdio";
export const TEAM_SUBROUTER_URLS = [
  "http://cmux-lawrences-mac-mini:31415",
  "http://cmux-lawrences-mac-mini.tail137216.ts.net:31415",
  "http://100.89.225.106:31415",
];

export interface Admission {
  profile: string;
  kind: string;
  argv0: string;
  /** `claude`, `codex` or `other`. */
  family: string;
}

type Profile = Record<string, unknown>;
type Route = "subrouter" | "direct";

const routeOf = (name: string): Route | undefined => (name === "claude-sr" ? "subrouter" : name === "claude" ? "direct" : undefined);
const routeCommand = (route: Route) => (route === "subrouter" ? "`sr claude proxy`" : "`claude`");
const basename = (word: string) => word.split("/").pop() ?? "";
const kindOf = (p: Profile) => (typeof p.kind === "string" ? p.kind : "acp");
const argvOf = (p: Profile): string[] => (Array.isArray(p.argv) ? p.argv.filter((w): w is string => typeof w === "string") : []);
const harnessesOf = (answer: unknown): Record<string, Profile> => {
  const h = (answer as { harnesses?: unknown } | null | undefined)?.harnesses;
  return h && typeof h === "object" && !Array.isArray(h) ? (h as Record<string, Profile>) : {};
};

function routeMatches(route: Route, argv: string[]): boolean {
  if (argv.length === 0) return false;
  const exe = basename(argv[0]);
  if (route === "direct") return exe === "claude";
  return (exe === "sr" || exe === "subrouter") && argv.length === 3 && argv[1] === "claude" && argv[2] === "proxy";
}

function routedToTeamSubrouter(p: Profile): boolean {
  const argv = argvOf(p);
  const env = p.env as Record<string, unknown> | undefined;
  const raw = env && typeof env.ANTHROPIC_BASE_URL === "string" ? env.ANTHROPIC_BASE_URL : undefined;
  const url = raw?.trim().replace(/\/+$/, "");
  return argv.length === 1 && basename(argv[0]) === "claude" && url !== undefined && TEAM_SUBROUTER_URLS.includes(url);
}

function whatIs(answer: unknown, name: string): string {
  const p = harnessesOf(answer)[name];
  if (!p) return `acpmux has no harness named ${name}`;
  const argv = argvOf(p);
  let text = `acpmux's ${name} is kind ${kindOf(p)} (${argv[0] ?? "no command"})`;
  if (typeof p.description === "string") text += `, "${p.description}"`;
  return text;
}

export const isRoute = (requested: string) => routeOf(requested) !== undefined;

/** The family of `harness`: the one acpmux reports, else from its kind and command words (codex before claude), never its name. */
export function harnessFamily(answer: unknown, harness: string): { family: string } | { error: string } {
  const p = harnessesOf(answer)[harness];
  if (!p) return { error: `acpmux has no harness named ${harness}` };
  if (typeof p.family === "string") return { family: p.family === "claude" || p.family === "codex" ? p.family : "other" };
  if (p.kind === CLAUDE_STDIO) return { family: "claude" };
  const words = argvOf(p).map((w) => basename(w).toLowerCase());
  for (const needle of ["codex", "claude"]) if (words.some((w) => w.includes(needle))) return { family: needle };
  return { family: "other" };
}

const byCodeUnits = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** Admits `requested` (a route or a profile name) against an `_acpmux/harnesses` answer, or says why not. */
export function admitHarness(answer: unknown, requested: string): { admitted: Admission } | { refused: string } {
  const route = routeOf(requested);
  if (!route) return admitProfile(answer, requested);
  const routed = (p: Profile) => route === "subrouter" && routedToTeamSubrouter(p);
  const found = Object.entries(harnessesOf(answer))
    .filter(([, p]) => kindOf(p) === CLAUDE_STDIO && p.unavailable === undefined && (routeMatches(route, argvOf(p)) || routed(p)))
    // A real `sr claude proxy` first, then the reserved name's profile.
    .sort(([an, ap], [bn, bp]) => Number(routed(ap)) - Number(routed(bp)) || Number(an !== requested) - Number(bn !== requested) || byCodeUnits(an, bn));
  const first = found[0];
  if (!first) {
    return {
      refused: `the Chief runs Claude only through acpmux's own Claude Code adapter (kind ${CLAUDE_STDIO}), and ${requested} asks for one running ${routeCommand(route)}; acpmux has none: ${whatIs(answer, requested)}`,
    };
  }
  return { admitted: { profile: first[0], kind: CLAUDE_STDIO, argv0: argvOf(first[1])[0] ?? "", family: "claude" } };
}

/** A profile by its exact name: refused when it is Claude and not kind `claude-stdio`. */
export function admitProfile(answer: unknown, profile: string): { admitted: Admission } | { refused: string } {
  const p = harnessesOf(answer)[profile];
  if (!p) return { refused: `acpmux has no harness named ${profile}` };
  const family = harnessFamily(answer, profile);
  if ("error" in family) return { refused: family.error };
  const kind = kindOf(p);
  if (family.family === "claude" && kind !== CLAUDE_STDIO) {
    return { refused: `the Chief runs Claude only through acpmux's own Claude Code adapter (kind ${CLAUDE_STDIO}); ${whatIs(answer, profile)}` };
  }
  return { admitted: { profile, kind, argv0: argvOf(p)[0] ?? "", family: family.family } };
}
