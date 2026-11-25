// Door A's page store (machineJoin.ts): the rows of `_acpmux/machine_candidates`, and the one join
// a row's click starts, with its confirmation, progress, held send and failure.
import { afterEach, describe, expect, test } from "bun:test";
import {
  arrivedMachine,
  candidatesFromReply,
  confirmJoin,
  endJoin,
  holdSendForJoin,
  joinNotListed,
  joinPicked,
  joinSeconds,
  machineJoinStateForTest,
  noteJoinProgress,
  retryJoin,
  setMachineJoinPort,
  setMachineJoinStateForTest,
  settle,
  splitCandidates,
  startJoin,
  type JoinCandidate,
} from "./machineJoin";
import { failureAction } from "./MachineJoinLine";

const mine: JoinCandidate = { name: "gcp-3", address: "gcp-3.tail.ts.net", found: "tailnet", mine: true };
const other: JoinCandidate = { name: "build-box", address: "build-box", found: "ssh-config", mine: false };

/// A port that records each join's params and never answers on its own.
function recordingPort() {
  const calls: Record<string, unknown>[] = [];
  setMachineJoinPort({
    candidates: () => Promise.resolve({ candidates: [] }),
    join: (params) => {
      calls.push(params);
      return new Promise(() => undefined);
    },
  });
  return calls;
}

afterEach(() => {
  setMachineJoinPort(undefined);
  setMachineJoinStateForTest(undefined);
});

describe("candidatesFromReply", () => {
  test("only a tailnet node the tailnet says is the person's is mine; malformed and repeated rows are left out", () => {
    const rows = candidatesFromReply({
      candidates: [
        { name: "gcp-3", address: "gcp-3.tail.ts.net", found: "tailnet", mine: true },
        { name: "lab", address: "lab", found: "ssh-config", mine: true },
        { name: "shared", address: "shared.tail.ts.net", found: "tailnet", mine: false },
        { name: "", address: "x" },
        { name: "dup", address: "GCP-3.tail.ts.net", found: "tailnet", mine: true },
        null,
      ],
    });
    expect(rows.map((row) => [row.name, row.mine])).toEqual([
      ["gcp-3", true],
      ["lab", false],
      ["shared", false],
    ]);
    expect(candidatesFromReply(undefined)).toEqual([]);
  });

  test("the person's own come first, each part by name", () => {
    const split = splitCandidates([other, { ...mine, name: "gcp-10" }, mine]);
    expect(split.mine.map((c) => c.name)).toEqual(["gcp-3", "gcp-10"]);
    expect(split.other.map((c) => c.name)).toEqual(["build-box"]);
  });
});

describe("a join", () => {
  test("one click on the person's own node sends the host and no confirmation, and never a token", () => {
    const calls = recordingPort();
    const id = startJoin(mine);
    expect(calls).toEqual([{ host: mine.address, name: mine.name, joinId: id }]);
    expect(machineJoinStateForTest().join?.phase).toBe("joining");
  });

  test("a host that asks first shows its login, and Add runs it confirmed", () => {
    const calls = recordingPort();
    const id = startJoin(other);
    settle(id, { ok: false, failure: { kind: "needs_confirmation" }, confirm: { login: "leo@build-box" } });
    const asked = machineJoinStateForTest().join!;
    expect(asked.phase).toBe("confirm");
    expect(asked.login).toBe("leo@build-box");
    confirmJoin();
    expect(calls[1]).toMatchObject({ host: "build-box", confirmed: true });
    expect(machineJoinStateForTest().join?.confirmed).toBe(true);
  });

  test("progress moves the step and seconds of this join only, and the line counts on", () => {
    recordingPort();
    const id = startJoin(mine, false, 1_000);
    noteJoinProgress({ joinId: "someone-else", step: "install", seconds: 9 }, 2_000);
    expect(machineJoinStateForTest().join?.step).toBe("reach");
    noteJoinProgress({ joinId: id, step: "install", seconds: 6 }, 2_000);
    const join = machineJoinStateForTest().join!;
    expect([join.step, join.seconds]).toEqual(["install", 6]);
    expect(joinSeconds(join, 4_500)).toBe(8);
  });

  test("a send while it runs is held, and goes once the machine is picked", async () => {
    recordingPort();
    const id = startJoin(mine);
    let sent = 0;
    let held = false;
    const went = new Promise<void>((resolve) => {
      held = holdSendForJoin(() => {
        sent += 1;
        resolve();
      });
    });
    expect(held).toBe(true);
    expect(machineJoinStateForTest().join?.queued).toBe(true);
    expect(sent).toBe(0);
    settle(id, { ok: true, seconds: 14, machine: { name: "gcp-3" } });
    expect(machineJoinStateForTest().join?.phase).toBe("joined");
    joinPicked(id);
    expect(machineJoinStateForTest().join).toBeUndefined();
    await went;
    expect(sent).toBe(1);
  });

  test("a failure drops the held send (the prompt stays in the composer) and Try Again keeps the confirmation", () => {
    const calls = recordingPort();
    const id = startJoin(other, true);
    let sent = 0;
    holdSendForJoin(() => (sent += 1));
    settle(id, { ok: false, failure: { kind: "needs_key", message: "denied", next: "ssh-copy-id build-box" } });
    const failed = machineJoinStateForTest().join!;
    expect([failed.phase, failed.failure?.kind]).toEqual(["failed", "needs_key"]);
    expect(holdSendForJoin(() => (sent += 1))).toBe(false);
    retryJoin();
    expect(calls[1]).toMatchObject({ host: "build-box", confirmed: true });
    expect(sent).toBe(0);
  });

  test("joined but never listed fails as no_peer; Dismiss clears the line", () => {
    recordingPort();
    const id = startJoin(mine);
    settle(id, { ok: true });
    joinNotListed(id);
    expect(machineJoinStateForTest().join?.failure?.kind).toBe("no_peer");
    endJoin();
    expect(machineJoinStateForTest().join).toBeUndefined();
  });

  test("with no acpmux connection the join fails at once", () => {
    startJoin(mine);
    expect(machineJoinStateForTest().join?.phase).toBe("failed");
  });

  test("the app's refusal for a signed-out person is not_signed_in, whose button is Sign In", async () => {
    setMachineJoinPort({
      candidates: () => Promise.resolve({}),
      join: () => Promise.reject(Object.assign(new Error("refused"), { reason: "not_signed_in" })),
    });
    startJoin(mine);
    await Promise.resolve();
    await Promise.resolve();
    expect(machineJoinStateForTest().join?.failure?.kind).toBe("not_signed_in");
    expect(failureAction("not_signed_in")).toBe("signIn");
    expect(failureAction("unsupported_platform")).toBe("addMachine");
    expect(failureAction("needs_key")).toBe("retry");
  });
});

describe("arrivedMachine", () => {
  const ready = () => true;
  test("the joined machine is found by the name it joined as, or the host's first label, never This Mac", () => {
    recordingPort();
    const id = startJoin(mine);
    settle(id, { ok: true, machine: { name: "GCP-3" } });
    const join = machineJoinStateForTest().join;
    const computers = [
      { id: "local", label: "gcp-3", kind: "local" },
      { id: "peer:gcp-3", label: "gcp-3", kind: "ssh" },
    ];
    expect(arrivedMachine(join, computers, ready)?.id).toBe("peer:gcp-3");
    expect(arrivedMachine(join, computers, () => false)).toBeUndefined();
  });
});
