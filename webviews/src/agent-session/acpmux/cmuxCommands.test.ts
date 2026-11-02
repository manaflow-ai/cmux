import { expect, test } from "bun:test";
import { cdFolder, cmuxCommandRefusal, composerCommand, mergedCommands } from "./cmuxCommands";
import { type SessionAuth, slashLogin, UNKNOWN_AUTH } from "./sessionAuth";

test("status is available before harness commands and stays cmux-owned", () => {
  const commands = mergedCommands([
    { name: "status", description: "agent status", source: "agent" },
    { name: "compact", description: "Compact context", source: "agent" },
  ]);

  expect(commands.map((command) => command.name)).toEqual([
    "model",
    "fast",
    "context",
    "plan",
    "import",
    "continue",
    "fork",
    "btw",
    "side",
    "status",
    "cd",
    "resume",
    "login",
    "compact",
    // Not advertised by this harness: cmux's passthrough fallback, after the harness's own.
    "clear",
  ]);
  expect(commands.find((command) => command.name === "status")?.source).toBe("cmux");
  expect(commands.find((command) => command.name === "side")).toMatchObject({
    source: "cmux",
    action: "side",
    descriptionKey: "composer.slashSide",
  });
});

test("status can be disabled while a pane is not ready", () => {
  const commands = mergedCommands([], new Set(["import"]));
  // The passthrough fallbacks stay: they are the harness's own commands, sent as typed.
  expect(commands.map((command) => command.name)).toEqual(["import", "compact", "clear"]);
});

test("/cd reads an absolute path as typed and a relative one against the chat's folder", () => {
  expect(cdFolder("/work/app/", "/home/me")).toBe("/work/app");
  expect(cdFolder("..", "/work/app")).toBe("/work");
  expect(cdFolder("./src/../lib", "/work/app")).toBe("/work/app/lib");
  expect(cdFolder("'/work/my app'", undefined)).toBe("/work/my app");
  expect(cdFolder("../../../..", "/work")).toBe("/");
  // The host's home is not the pane's to spell; a relative path needs a chat folder.
  expect(cdFolder("~/src", "/work")).toBeUndefined();
  expect(cdFolder("src", undefined)).toBeUndefined();
  expect(cdFolder("", "/work")).toBeUndefined();
});

test("/cd is cmux's, refused on New Tab and for a path it cannot read", () => {
  const cd = composerCommand("/cd ../lib")!;
  expect(cd).toMatchObject({ kind: "cmux", args: "../lib", command: { action: "cd" } });
  if (cd.kind !== "cmux") throw new Error("not cmux");
  const state = {
    summary: true,
    forkable: true,
    sideAvailable: true,
    canContinue: true,
    sideSessions: true,
    session: true,
    isSideSession: false,
    targets: [],
  };
  expect(cmuxCommandRefusal(cd.command, "../lib", { ...state, cwd: "/work/app" })).toBeUndefined();
  // Bare: the folder browser.
  expect(cmuxCommandRefusal(cd.command, "", state)).toBeUndefined();
  expect(cmuxCommandRefusal(cd.command, "~/x", { ...state, cwd: "/work" })).toBe("composer.cmuxCdPath");
  expect(cmuxCommandRefusal(cd.command, "lib", state)).toBe("composer.cmuxCdPath");
  expect(cmuxCommandRefusal(cd.command, "/work", { ...state, newTab: true })).toBe("composer.cmuxCdNewTab");
});

// Lawrence, via Leo (ask-946b78453c): "in gui, having /resume would be nice, maybe /login as well".
test("/resume and /login are cmux's in every harness chat, never refused as terminal-only", () => {
  for (const harness of ["claude", "claude-sr", "codex", undefined]) {
    expect(composerCommand("/resume", harness)).toMatchObject({ kind: "cmux", command: { action: "resume" } });
    expect(composerCommand("/login", harness)).toMatchObject({ kind: "cmux", command: { action: "login" } });
  }
  // The rest of Claude Code's terminal-only commands still say so.
  expect(composerCommand("/logout", "claude")).toMatchObject({ kind: "cliOnly", name: "logout" });
  const names = mergedCommands([{ name: "resume", description: "Resume a conversation", source: "agent" }]).map(
    (command) => command.name,
  );
  expect(names.filter((name) => name === "resume")).toHaveLength(1);
  expect(names).toContain("login");
});

test("/login signs in with acpmux's command, else the harness's own login on a plain local chat", () => {
  const signedOut: SessionAuth = {
    state: "signedOut",
    source: "authCheck",
    evidenceAt: 1,
    harness: "claude",
    host: null,
    routeId: null,
    login: { kind: "terminal", command: "CLAUDE_CONFIG_DIR=/a claude auth login" },
  };
  expect(slashLogin(signedOut, "claude /login")).toEqual({ kind: "session" });
  const ready: SessionAuth = {
    state: "ready",
    source: "turn",
    evidenceAt: 1,
    harness: "claude",
    host: null,
    routeId: null,
  };
  expect(slashLogin(ready, "claude /login")).toEqual({ kind: "terminal", command: "claude /login" });
  // A route may keep its own account home: the default login would sign in the wrong one.
  expect(slashLogin({ ...ready, routeId: "claude-two" }, "claude /login")).toBeUndefined();
  // Another host's harness signs in there, not in a terminal here.
  expect(slashLogin({ ...ready, host: "mini-3" }, "claude /login")).toBeUndefined();
  // Only acpmux's `host: null` says this Mac: an unknown or hostless answer gets no default login.
  expect(slashLogin(UNKNOWN_AUTH, "claude /login")).toBeUndefined();
  expect(slashLogin({ ...ready, host: undefined }, "claude /login")).toBeUndefined();
  expect(slashLogin(undefined, "claude /login")).toBeUndefined();
  expect(slashLogin(ready, undefined)).toBeUndefined();
  expect(slashLogin(ready, "  ")).toBeUndefined();
});

test("a Claude skill named like a cmux command stays in the list, and mid-prompt it is the only one", async () => {
  const { slashMatches } = await import("./slashCommands");
  const commands = mergedCommands([
    { name: "plan", description: "Plan the work", source: "skill" },
    { name: "context", description: "", source: "agent" },
  ]);
  expect(commands.filter((command) => command.name === "plan").map((command) => command.source)).toEqual([
    "cmux",
    "skill",
  ]);
  // The harness's own command with a cmux name still gives way to cmux's.
  expect(commands.filter((command) => command.name === "context").map((command) => command.source)).toEqual(["cmux"]);
  expect(
    slashMatches(commands, { query: "pla", length: 4, leading: false }).map((match) => match.command.source),
  ).toEqual(["skill"]);
});
