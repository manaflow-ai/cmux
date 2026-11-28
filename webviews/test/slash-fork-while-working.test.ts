// cmux#59876: "/fork is unavailable in this chat and I can't do anything" while a turn ran. /fork
// now forks a working chat as it is now (Fork Conversation's `chat.forkTo`), as /side already did;
// an idle chat still forks through its latest finished turn (`chat.fork`).
import { afterEach, expect, test } from "bun:test";
import { handleCmuxCommand, type CmuxCommandDeps } from "../src/agent-session/acpmux/pane/cmuxCommands";
import { CMUX_COMMANDS } from "../src/agent-session/acpmux/cmuxCommands";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const fork = CMUX_COMMANDS.find((command) => command.action === "fork");
if (!fork) throw new Error("no /fork command");

const calls: { method: string; params: unknown }[] = [];
const actions = new Proxy(
  {},
  {
    get: (_target, method: string) => (params: unknown) => {
      calls.push({ method, params });
      return Promise.resolve({});
    },
  },
);

afterEach(() => {
  calls.length = 0;
  delete (globalThis as { window?: unknown }).window;
});

function run(snapshot: Partial<AcpmuxSnapshot>, forkSeq: number | undefined) {
  (globalThis as { window?: unknown }).window = { cmuxAcpmuxActions: actions };
  const deps = {
    snapshot: { rows: [], connection: "connected", canFork: true, ...snapshot } as AcpmuxSnapshot,
    forkSeq,
    commandState: () => ({
      summary: true,
      forkable: true,
      sideAvailable: true,
      canContinue: true,
      sideSessions: true,
      session: true,
      isSideSession: false,
      targets: [],
    }),
    ignoreFailure: (result: Promise<unknown>) => void result.catch(() => undefined),
    t: (key: string) => key,
  } as unknown as CmuxCommandDeps;
  return handleCmuxCommand(deps, fork!, "");
}

test("/fork on a working chat forks it as it is now, without waiting for the turn", () => {
  expect(run({ isWorking: true }, 7)).toBe(true);
  // Dispatched synchronously, in the same task as Return: nothing waits on the running turn.
  expect(calls).toEqual([{ method: "chat.forkTo", params: {} }]);
});

test("/fork on an idle chat forks through its latest finished turn", () => {
  expect(run({ isWorking: false }, 7)).toBe(true);
  expect(calls).toEqual([{ method: "chat.fork", params: { throughSeq: 7 } }]);
});
