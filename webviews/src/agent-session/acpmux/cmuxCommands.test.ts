import { expect, test } from "bun:test";
import { cdFolder, cmuxCommandRefusal, composerCommand, mergedCommands } from "./cmuxCommands";

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
