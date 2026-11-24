import { expect, test } from "bun:test";
import { cmuxCommandRefusal, composerCommand } from "./cmuxCommands";
import {
  commandPlace,
  dropHandedCloudStart,
  HANDED_CLOUD_START_TTL_MS,
  handCloudStart,
  receiveHandedCloudStart,
  takeHandedCloudStart,
} from "./commandPlace";

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

test("a started chat's /side and /cd --on cloud open New Cloud Chat; /fork and /continue say why not", () => {
  const withCloud = { ...started, cloudStart: true };
  expect(cmuxCommandRefusal(owned("/side").command, "--on cloud fix it", withCloud)).toBeUndefined();
  // A Cloud start needs nothing to fork: a chat with no finished turn still opens one.
  expect(
    cmuxCommandRefusal(owned("/side").command, "--on cloud", {
      ...withCloud,
      sideAvailable: false,
      sideFork: "nothingYet",
    }),
  ).toBeUndefined();
  expect(cmuxCommandRefusal(owned("/cd").command, "--on cloud ../lib", withCloud)).toBeUndefined();
  expect(cmuxCommandRefusal(owned("/cd").command, "--on cloud ~/x", withCloud)).toBe("composer.cmuxCdPath");
  // Quick Chat opens no tab beside it.
  expect(cmuxCommandRefusal(owned("/side").command, "--on cloud fix", started)).toBe("composer.cmuxSideUnavailable");
  expect(cmuxCommandRefusal(owned("/cd").command, "--on cloud ../lib", started)).toBe("composer.cmuxUnavailable");
  // A new chat has no chat to start a side chat beside.
  expect(cmuxCommandRefusal(owned("/side").command, "--on cloud fix", { ...unstarted, cloudStart: true })).toBe(
    "composer.cmuxSideUnavailable",
  );
  for (const [text, args] of [
    ["/fork", "--on cloud"],
    ["/continue", "--on cloud codex"],
  ] as const)
    expect(cmuxCommandRefusal(owned(text).command, args, withCloud)).toBe("composer.cmuxOnCloudCarries");
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

function memoryStore() {
  const items = new Map<string, string>();
  return {
    getItem: (name: string) => items.get(name) ?? null,
    setItem: (name: string, value: string) => void items.set(name, value),
    removeItem: (name: string) => void items.delete(name),
    size: () => items.size,
  };
}

type Handshake = {
  sessionId?: string;
  draft?: string;
  newTab?: unknown;
  pickCloud?: unknown;
  cloudStartHandoff?: unknown;
};
const opened = (token: string | undefined, extra: Handshake = {}): Handshake => ({
  ...extra,
  pickCloud: true,
  ...(token ? { cloudStartHandoff: token } : {}),
});

test("a /side --on cloud prompt reaches the tab opened with its token, once", () => {
  const store = memoryStore();
  const token = handCloudStart(store, { prompt: "fix the tests" }, 1_000, "token-side-0000000001");
  expect(token).toBe("token-side-0000000001");
  const page = receiveHandedCloudStart(opened(token), false, store, 1_500);
  // Cloud is picked and the prompt waits in the composer for the person's Send.
  expect(page).toEqual({ host: { pickCloud: true, cloudStartHandoff: token, draft: "fix the tests" } });
  // A reload, or the same token again, gets nothing: read once.
  expect(receiveHandedCloudStart(opened(token), false, store, 1_600)).toEqual({ host: opened(token) });
  expect(store.size()).toBe(0);
});

test("a second tab never takes another tab's hand-off", () => {
  const store = memoryStore();
  const mine = handCloudStart(store, { prompt: "mine" }, 1_000, "token-mine-0000000001");
  const theirs = handCloudStart(store, { cwd: "/work/lib" }, 1_000, "token-theirs-00000001");
  // New Cloud Chat from the palette (no token), or a chat that already has a session, takes nothing.
  expect(receiveHandedCloudStart(opened(undefined), false, store, 1_100).host).toEqual(opened(undefined));
  expect(receiveHandedCloudStart(opened(mine, { sessionId: "s1" }), false, store, 1_100).host.draft).toBeUndefined();
  // A reconnect is never a new tab opening.
  expect(receiveHandedCloudStart(opened(mine), true, store, 1_100).host.draft).toBeUndefined();
  // Each tab gets its own: the /cd folder goes only to its token's tab.
  expect(receiveHandedCloudStart(opened(theirs, { newTab: true }), false, store, 1_200)).toEqual({
    host: { pickCloud: true, cloudStartHandoff: theirs, newTab: { cwd: "/work/lib" } },
    folder: "/work/lib",
  });
  expect(receiveHandedCloudStart(opened(mine), false, store, 1_300).host.draft).toBe("mine");
  expect(store.size()).toBe(0);
});

test("a hand-off past its time, or one whose tab did not open, is dropped", () => {
  const store = memoryStore();
  const late = handCloudStart(store, { prompt: "late" }, 1_000, "token-late-0000000001") ?? "";
  expect(takeHandedCloudStart(store, late, 1_000 + HANDED_CLOUD_START_TTL_MS + 1)).toBeUndefined();
  const refused = handCloudStart(store, { prompt: "refused" }, 2_000, "token-refused-0000001");
  dropHandedCloudStart(store, refused);
  expect(store.size()).toBe(0);
  // The app's own seed keeps its draft; a relative or empty folder is never handed on.
  const seeded = handCloudStart(store, { prompt: "fix", cwd: "lib" }, 3_000, "token-seeded-00000001");
  expect(receiveHandedCloudStart(opened(seeded, { draft: "app's own" }), false, store, 3_100)).toEqual({
    host: { pickCloud: true, cloudStartHandoff: seeded, draft: "app's own" },
  });
  // No storage: nothing is kept, and the tab opens without it.
  expect(handCloudStart(undefined, { prompt: "x" }, 1)).toBeUndefined();
});
