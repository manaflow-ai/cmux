import { expect, test } from "bun:test";
import { cmuxCommandRefusal, composerCommand } from "./cmuxCommands";
import {
  commandPlace,
  HANDED_CLOUD_START_TTL_MS,
  handCloudStart,
  takeHandedCloudStart,
  withHandedCloudStart,
} from "./commandPlace";

// Leo, 2026-11-06: "Shared chat commands can start in cloud."

function memoryStore() {
  const items = new Map<string, string>();
  return {
    getItem: (name: string) => items.get(name) ?? null,
    setItem: (name: string, value: string) => void items.set(name, value),
    removeItem: (name: string) => void items.delete(name),
    size: () => items.size,
  };
}

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
  cloudStart: true,
};

function owned(text: string) {
  const command = composerCommand(text);
  if (command?.kind !== "cmux") throw new Error(`${text} is not cmux's`);
  return command;
}

test("/side --on cloud starts a new Cloud chat from a chat on this Mac, fork or no fork", () => {
  const side = owned("/side --on cloud fix the tests");
  expect(side.args).toBe("--on cloud fix the tests");
  expect(cmuxCommandRefusal(side.command, side.args, started)).toBeUndefined();
  // Nothing to fork yet, or no local folder to fork in: a Cloud start needs neither.
  expect(
    cmuxCommandRefusal(side.command, side.args, { ...started, sideAvailable: false, sideFork: "nothingYet" }),
  ).toBeUndefined();
  // New Tab and Quick Chat have their own Where menu, or no tab to open beside.
  expect(cmuxCommandRefusal(side.command, side.args, { ...started, newTab: true })).toBe(
    "composer.cmuxSideUnavailable",
  );
  expect(cmuxCommandRefusal(side.command, side.args, { ...started, cloudStart: false })).toBe(
    "composer.cmuxSideUnavailable",
  );
  // A Cloud chat's /side already forks on its machine: --on cloud is that, with its own rules.
  expect(cmuxCommandRefusal(side.command, side.args, { ...started, inCloud: true, sideFork: "nothingYet" })).toBe(
    "notice.forkNothingYet",
  );
  // Without --on nothing changes: a chat with nothing to fork says so.
  expect(cmuxCommandRefusal(side.command, "fix", { ...started, sideFork: "nothingYet" })).toBe("notice.forkNothingYet");
});

test("/cd --on cloud reads its folder as /cd does", () => {
  const cd = owned("/cd --on cloud ../lib");
  expect(cmuxCommandRefusal(cd.command, cd.args, started)).toBeUndefined();
  expect(cmuxCommandRefusal(cd.command, "--on cloud", started)).toBeUndefined();
  expect(cmuxCommandRefusal(cd.command, "--on cloud ~/x", started)).toBe("composer.cmuxCdPath");
  expect(cmuxCommandRefusal(cd.command, "--on cloud /x", { ...started, newTab: true })).toBe("composer.cmuxCdNewTab");
  // --on here is plain /cd.
  expect(cmuxCommandRefusal(cd.command, "--on here ../lib", started)).toBeUndefined();
  expect(cmuxCommandRefusal(cd.command, "--on vm ../lib", started)).toBe("composer.cmuxOnPlace");
});

test("/fork and /continue take the chat with them, so --on cloud says where to go instead", () => {
  const fork = owned("/fork --on cloud");
  expect(cmuxCommandRefusal(fork.command, fork.args, started)).toBe("composer.cmuxOnCloudCarries");
  expect(cmuxCommandRefusal(fork.command, "--on here", started)).toBeUndefined();
  const next = owned("/continue --on cloud codex");
  expect(cmuxCommandRefusal(next.command, next.args, started)).toBe("composer.cmuxOnCloudCarries");
  // /btw's words are its question, --on included.
  const btw = owned("/btw --on cloud is this right?");
  expect(cmuxCommandRefusal(btw.command, btw.args, started)).toBeUndefined();
});

test("a handed Cloud start goes once to the tab it opened, within its time", () => {
  const store = memoryStore();
  handCloudStart(store, { prompt: "fix the tests" }, 1_000);
  // A tab that New Cloud Chat did not open takes nothing, and leaves it.
  expect(takeHandedCloudStart(store, { cwd: "/work/app" }, 1_500)).toBeUndefined();
  expect(takeHandedCloudStart(store, { pickCloud: true }, 1_500)).toEqual({ prompt: "fix the tests" });
  expect(takeHandedCloudStart(store, { pickCloud: true }, 1_600)).toBeUndefined();

  // /cd's goes to the tab that opened in its folder.
  handCloudStart(store, { cwd: "/work/lib" }, 2_000);
  expect(takeHandedCloudStart(store, { cwd: "/work/other", pickCloud: true }, 2_100)).toBeUndefined();
  expect(takeHandedCloudStart(store, { cwd: "/work/lib/" }, 2_100)).toEqual({ cwd: "/work/lib" });

  // Too late: dropped.
  handCloudStart(store, { prompt: "late" }, 3_000);
  expect(takeHandedCloudStart(store, { pickCloud: true }, 3_000 + HANDED_CLOUD_START_TTL_MS + 1)).toBeUndefined();
  expect(store.size()).toBe(0);
});

type Handshake = { cwd?: string; draft?: string; newTab?: unknown; pickCloud?: unknown };
const page = (host: Handshake, handed: Parameters<typeof withHandedCloudStart>[1]): Record<string, unknown> =>
  withHandedCloudStart(host, handed);

test("the tab a handed start opened picks Cloud and starts with the prompt", () => {
  expect(page({ cwd: "/w" }, undefined)).toEqual({ cwd: "/w" });
  expect(page({ cwd: "/w" }, { cwd: "/w" })).toEqual({ cwd: "/w", pickCloud: true });
  expect(page({}, { prompt: "fix" })).toEqual({ pickCloud: true, draft: "fix" });
  // A New Tab page starts with it in its own field.
  expect(page({ newTab: true }, { prompt: "fix" })).toEqual({
    pickCloud: true,
    draft: "fix",
    newTab: { draft: "fix" },
  });
  // The app's own seed wins.
  expect(page({ draft: "mine", newTab: { draft: "mine" } }, { prompt: "fix" })).toEqual({
    pickCloud: true,
    draft: "mine",
    newTab: { draft: "mine" },
  });
});
