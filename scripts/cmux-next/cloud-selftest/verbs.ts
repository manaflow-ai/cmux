/**
 * The verbs cmux-tui offers, read from its Rust sources (no build): the drift guard of the action catalogue
 * (cloud-selftest.test.ts fails when an action names a verb that is not here).
 *
 * - `cli/cloud_help.rs`: every `verb("NAME", ...)` of `cmux cloud --help` (the catalog's offered `cloud …` actions,
 *   which `cloud_help/tests.rs` keeps equal to plans/cmux-next/action-surfaces.json), and the `cmux cloud …` lines of
 *   its help text (team keys, secrets, client sessions).
 * - The CLI's own multiplayer verbs: the `cmux …` usage lines of `cli/cloud_team_keys.rs`, `cli/cloud_machine_auth.rs`,
 *   `cli/inference_gateway_admin.rs`, `cli/inference_gateway.rs` and `cli/cloud_client_session.rs`.
 * - `link/chat_cli.rs`: its usage lines and its verb match arms (`"list" => Verb::List`, `"send" => {`) as
 *   `link chat VERB`.
 * - `cli/app.rs`: its `("app", Some("ping"))` arms as `app ping`.
 */
import { readFileSync } from "node:fs";
import path from "node:path";

/** The repository root (this file is scripts/cmux-next/cloud-selftest/verbs.ts). */
export const REPO_ROOT = path.resolve(import.meta.dir, "../../..");
const SRC = "cmux-tui/crates/cmux-tui/src";

export const VERB_SOURCES = {
  help: `${SRC}/cli/cloud_help.rs`,
  usage: [`${SRC}/cli/cloud_team_keys.rs`, `${SRC}/cli/cloud_machine_auth.rs`, `${SRC}/cli/inference_gateway_admin.rs`, `${SRC}/cli/inference_gateway.rs`, `${SRC}/cli/cloud_client_session.rs`, `${SRC}/link/chat_cli.rs`],
  linkChat: `${SRC}/link/chat_cli.rs`,
  app: `${SRC}/cli/app.rs`,
};

/** `cmux WORDS` command names in a text: lowercase words up to the first flag, placeholder or `[`. */
export function usageCommands(text: string): string[] {
  const out = new Set<string>();
  for (const m of text.matchAll(/\bcmux((?: [a-z][a-z0-9-]*)+)/g)) out.add(m[1]!.trim());
  return [...out];
}

/** `verb("NAME", ...)` names of cloud_help.rs, as `cloud NAME`. */
export function helpVerbs(rust: string): string[] {
  return [...rust.matchAll(/\bverb\(\s*"([a-z][a-z0-9-]*)"/g)].map((m) => `cloud ${m[1]}`);
}

/** The verb arms of link/chat_cli.rs's parse, as `link chat VERB`. */
export function linkChatVerbs(rust: string): string[] {
  return [...rust.matchAll(/^\s*"([a-z]+)" => (?:Verb::|\{)/gm)].map((m) => `link chat ${m[1]}`);
}

/** `("app", Some("VERB"))` arms of cli/app.rs, as `app VERB`. */
export function appVerbs(rust: string): string[] {
  return [...rust.matchAll(/\("app", Some\("([a-z][a-z0-9-]*)"\)\)/g)].map((m) => `app ${m[1]}`);
}

/** Every offered command (words joined by spaces), from the sources under `root`. */
export function offeredVerbs(root = REPO_ROOT, read: (p: string) => string = (p) => readFileSync(path.join(root, p), "utf8")): Set<string> {
  const help = read(VERB_SOURCES.help);
  return new Set([
    ...helpVerbs(help),
    ...usageCommands(help),
    ...VERB_SOURCES.usage.flatMap((f) => usageCommands(read(f))),
    ...linkChatVerbs(read(VERB_SOURCES.linkChat)),
    ...appVerbs(read(VERB_SOURCES.app)),
  ]);
}

/**
 * Whether `words` is an offered verb: equal to an offered command, or its leading words (a usage line such as
 * `cmux cloud team-keys set claude|codex` names `cloud team-keys set`). `cmux vm X` is `cmux cloud X`'s alias.
 */
export function isOffered(words: string[], offered: Set<string>): boolean {
  const want = words.join(" ");
  const alias = words[0] === "vm" ? ["cloud", ...words.slice(1)].join(" ") : want;
  return [...offered].some((o) => [want, alias].some((w) => o === w || o.startsWith(`${w} `)));
}

/** Whether a raw command line runs `verb`: its words past the leading global flags (`--json`) start with it. */
export function argvRuns(argv: string[], verb: string): boolean {
  const words = argv.slice(argv.findIndex((w) => !w.startsWith("-")));
  const want = verb.split(" ");
  return want.every((w, i) => words[i] === w);
}
