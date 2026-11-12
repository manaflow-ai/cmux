import { expect, test } from "bun:test";
import { cmuxCommandRefusal, composerCommand } from "./cmuxCommands";
import { commandPlace } from "./commandPlace";

// Leo, 2026-11-06: "Shared chat commands can start in cloud."

test("--on takes the CLI's words before a command's arguments", () => {
  expect(commandPlace("--on cloud fix the tests")).toEqual({ place: "cloud", rest: "fix the tests" });
  expect(commandPlace("--on=cloud ../lib")).toEqual({ place: "cloud", rest: "../lib" });
  expect(commandPlace("--on here")).toEqual({ place: "here", rest: "" });
  expect(commandPlace("--on CLOUD")).toEqual({ place: "cloud", rest: "" });
  // No --on: where the command ran before, the arguments as typed.
  expect(commandPlace("fix --on cloud later")).toEqual({ rest: "fix --on cloud later" });
  expect(commandPlace("--online docs")).toEqual({ rest: "--online docs" });
  expect(commandPlace(undefined)).toEqual({ rest: "" });
  // The composer starts a chat here or in Cloud; a VM or a device is the CLI's or the Where menu's.
  expect(commandPlace("--on vm:new hi")).toEqual({ refused: true, on: "vm:new" });
  expect(commandPlace("--on")).toEqual({ refused: true, on: "" });
});

const started = {
  summary: true,
  forkable: true,
  sideAvailable: true,
  canContinue: true,
  sideSessions: true,
  session: true,
  isSideSession: false,
  targets: [],
  cwd: "/work/app",
};
/// A chat tab with no turn yet: its first Send starts it, here or in Cloud.
const unstarted = { ...started, summary: false, forkable: false, session: false, canContinue: false };

function owned(text: string) {
  const command = composerCommand(text);
  if (command?.kind !== "cmux") throw new Error(`${text} is not cmux's`);
  return command;
}

test("/cd --on cloud in a new chat picks its folder for a Cloud start, read as /cd reads it", () => {
  const cd = owned("/cd --on cloud ../lib");
  expect(cd.args).toBe("--on cloud ../lib");
  expect(cmuxCommandRefusal(cd.command, cd.args, unstarted)).toBeUndefined();
  // Bare: the folder browser, then Cloud.
  expect(cmuxCommandRefusal(cd.command, "--on cloud", unstarted)).toBeUndefined();
  expect(cmuxCommandRefusal(cd.command, "--on=cloud ~/x", unstarted)).toBe("composer.cmuxCdPath");
  expect(cmuxCommandRefusal(cd.command, "--on cloud /x", { ...unstarted, newTab: true })).toBe("composer.cmuxCdNewTab");
  expect(cmuxCommandRefusal(cd.command, "--on vm ../lib", unstarted)).toBe("composer.cmuxOnPlace");
});

test("a started chat's --on cloud says how to start one in Cloud instead of starting one here", () => {
  // The page cannot open another tab in Cloud for a started chat, so it never starts one here.
  expect(cmuxCommandRefusal(owned("/cd").command, "--on cloud ../lib", started)).toBe("composer.cmuxOnCloudStarted");
  // /side, /fork and /continue take the chat with them, so they run where it runs.
  for (const [text, args] of [
    ["/side", "--on cloud fix it"],
    ["/fork", "--on cloud"],
    ["/continue", "--on cloud codex"],
  ] as const)
    expect(cmuxCommandRefusal(owned(text).command, args, started)).toBe("composer.cmuxOnCloudCarries");
});

test("--on here, a Cloud chat's --on cloud, and no --on keep each command as it was", () => {
  const cd = owned("/cd").command;
  expect(cmuxCommandRefusal(cd, "--on here ../lib", started)).toBeUndefined();
  // A Cloud chat's /cd and /side already run on its machine.
  expect(cmuxCommandRefusal(cd, "--on cloud ../lib", { ...started, inCloud: true })).toBeUndefined();
  const side = owned("/side").command;
  expect(cmuxCommandRefusal(side, "--on cloud fix", { ...started, inCloud: true, sideFork: "nothingYet" })).toBe(
    "notice.forkNothingYet",
  );
  expect(cmuxCommandRefusal(side, "fix", { ...started, sideFork: "nothingYet" })).toBe("notice.forkNothingYet");
  expect(cmuxCommandRefusal(owned("/fork").command, "--on here", started)).toBeUndefined();
  // /btw's words are its question, --on included.
  expect(cmuxCommandRefusal(owned("/btw").command, "--on cloud is this right?", started)).toBeUndefined();
});
