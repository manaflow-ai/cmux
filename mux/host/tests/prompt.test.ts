import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { muxPaths } from "../src/paths.ts";
import { writeSessionDir } from "../src/session-dir.ts";

// The CLAUDE.md the mux's session directory gets tells the agent which `cmux`
// commands to run. The cmux-next CLI has no classic verbs (`list-workspaces`,
// `new-workspace`, `read-screen` exit 2 as an unknown scope), so the commands
// it names must be the current resource verbs.

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

function writtenPrompt(mcp: boolean): string {
  const dir = mkdtempSync("/tmp/muxp-");
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const paths = muxPaths(dir);
  writeSessionDir(paths, ["mux"], {}, { mcp });
  return readFileSync(join(paths.session, "CLAUDE.md"), "utf8");
}

/** Every inline `cmux ...` command the prompt names. */
function cmuxCommands(prompt: string): string[] {
  return [...prompt.matchAll(/`(cmux [^`]+)`/g)].map((match) => match[1]!.replace(/\s+/g, " "));
}

const CLASSIC_VERBS = ["list-workspaces", "new-workspace", "read-screen", "send-keys", "list-panes", "new-split"];

test("the CLI prompt names only cmux-next verbs", () => {
  const commands = cmuxCommands(writtenPrompt(false));
  expect(commands.length).toBeGreaterThan(0);
  for (const command of commands) {
    const verb = command.split(" ")[1]!;
    expect(CLASSIC_VERBS).not.toContain(verb);
  }
  expect(commands).toContain("cmux workspace list");
  expect(commands).toContain("cmux workspace create --name X --cwd DIR");
  expect(commands).toContain("cmux terminal <term_id> screen read");
});

test("the MCP prompt names no classic verb either", () => {
  for (const command of cmuxCommands(writtenPrompt(true))) {
    expect(CLASSIC_VERBS).not.toContain(command.split(" ")[1]!);
  }
});
