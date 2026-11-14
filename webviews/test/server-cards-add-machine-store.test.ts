// The Add Machine card's store against a fake host: an open fills the fields once, the tailnet
// list loads plain then probed, a pick fills the field (nothing runs), Add sends the fields (a
// picked agent peer's name with them), Change Host forgets the run and keeps the fields, and the
// keys press the card's own buttons (ported from AddMachineFlowTests when the card moved to React).
import { describe, expect, test } from "bun:test";
import { AddMachineStore, viewOf } from "../src/pages/server-cards/add-machine/store";
import type { AddMachineStatus, HostCandidate } from "../src/pages/server-cards/add-machine/types";

class FakeHost {
  status: AddMachineStatus = { request: { seq: 1, mode: { kind: "add" } } };
  calls: { op: string; params: unknown }[] = [];
  candidateAnswers: (HostCandidate[] | null)[] = [];
  private listener?: (event: unknown) => void;

  async call<T>(op: string, params?: unknown): Promise<T> {
    this.calls.push({ op, params });
    switch (op) {
      case "cmux.addMachine.status":
        return structuredClone(this.status) as T;
      case "cmux.addMachine.parse": {
        const text = (params as { text: string }).text.trim();
        if (!text || text.includes(" ") || text.includes(":")) return null as T;
        const host = text.split("@").at(-1)!;
        return { host: text, shortName: host.split(".")[0] } as T;
      }
      case "cmux.addMachine.candidates":
        return (this.candidateAnswers.length ? this.candidateAnswers.shift() : []) as T;
      default:
        return null as T;
    }
  }

  async subscribe(_stream: string, onEvent: (event: unknown) => void) {
    this.listener = onEvent;
    return () => {};
  }

  change(status: AddMachineStatus) {
    this.status = status;
    this.listener?.({});
  }

  ops(name: string) {
    return this.calls.filter((call) => call.op === `cmux.addMachine.${name}`).map((call) => call.params);
  }
}

const settle = async () => {
  for (let index = 0; index < 20; index++) await Promise.resolve();
};

const candidate = (patch: Partial<HostCandidate>): HostCandidate => ({
  id: "hb",
  name: "huge-blue",
  os: "linux",
  online: true,
  alreadyPeer: false,
  inApp: false,
  destination: "huge-blue.tail1.ts.net",
  pickable: true,
  ...patch,
});

async function opened(host: FakeHost) {
  let closed = 0;
  const store = new AddMachineStore(host, () => closed++);
  await store.start();
  await settle();
  return { store, closed: () => closed };
}

describe("Add Machine store", () => {
  test("a destination from outside only fills the field; Add runs on the press", async () => {
    const host = new FakeHost();
    host.status = { request: { seq: 4, mode: { kind: "add" }, destination: "hb", name: "lab" } };
    const { store } = await opened(host);
    expect(store.getSnapshot().destination).toBe("hb");
    expect(store.getSnapshot().name).toBe("lab");
    expect(host.ops("add")).toEqual([]);
    const view = viewOf(store.getSnapshot());
    expect(view.phase).toBe("pick");
    expect(view.buttons.at(-1)).toEqual({ action: "add", key: "return", enabled: true });
    await store.submit();
    expect(host.ops("add")).toEqual([{ destination: "hb", name: "lab" }]);
  });

  test("an empty field cannot add; the Name field defaults to the short host", async () => {
    const host = new FakeHost();
    const { store } = await opened(host);
    expect(viewOf(store.getSnapshot()).buttons.at(-1)?.enabled).toBe(false);
    await store.submit();
    expect(host.ops("add")).toEqual([]);
    store.setDestination("leo@huge-blue.ts.net");
    await settle();
    expect(viewOf(store.getSnapshot()).defaultName).toBe("huge-blue");
    store.setName("  ");
    await store.perform("add");
    expect(host.ops("add")).toEqual([{ destination: "leo@huge-blue.ts.net", name: "huge-blue" }]);
  });

  test("the plain list shows first and stays when the probe fails; without Tailscale it hides", async () => {
    const host = new FakeHost();
    const plain = candidate({});
    host.candidateAnswers = [[plain], null];
    const { store } = await opened(host);
    expect(store.getSnapshot().candidates).toEqual({ kind: "loaded", list: [plain] });
    expect(host.ops("candidates")).toEqual([{ probe: false }, { probe: true }]);
    const none = new FakeHost();
    none.candidateAnswers = [null];
    const hidden = await opened(none);
    expect(hidden.store.getSnapshot().candidates).toEqual({ kind: "unavailable" });
    expect(none.ops("candidates")).toEqual([{ probe: false }]);
  });

  test("a pick fills the field and runs nothing; an agent peer is added by its peer name", async () => {
    const host = new FakeHost();
    const peer = candidate({ alreadyPeer: true, peer: "hb", destination: "huge-blue" });
    const off = candidate({ id: "off", pickable: false, destination: "off" });
    host.candidateAnswers = [
      [peer, off],
      [peer, off],
    ];
    const { store } = await opened(host);
    store.pick(off);
    expect(store.getSnapshot().destination).toBe("");
    store.pick(peer);
    await settle();
    expect(store.getSnapshot().destination).toBe("huge-blue");
    expect(viewOf(store.getSnapshot()).defaultName).toBe("hb");
    expect(host.ops("add")).toEqual([]);
    await store.perform("add");
    expect(host.ops("add")).toEqual([{ destination: "huge-blue", name: "hb", peer: "hb" }]);
    // Typing over the field leaves the peer path: Add enrolls what was typed.
    store.setDestination("leo@huge-blue");
    await settle();
    await store.perform("add");
    expect(host.ops("add").at(-1)).toEqual({ destination: "leo@huge-blue", name: "huge-blue" });
  });

  test("a run shows its layout; Change Host forgets it and keeps the fields", async () => {
    const host = new FakeHost();
    host.status = {
      request: { seq: 2, mode: { kind: "add" }, destination: "leo@huge-blu", name: "lab" },
    };
    const { store } = await opened(host);
    const fail = JSON.stringify({
      step: "reach",
      state: "fail",
      detail: "no route",
      fix: "Check the host name.",
    });
    host.change({
      ...host.status,
      run: {
        id: 1,
        host: "leo@huge-blu",
        name: "lab",
        outcome: "failed",
        events: [
          { kind: "start" },
          { kind: "line", line: fail },
          {
            kind: "line",
            line: `{"report":{"name":"lab","host":"leo@huge-blu","ok":false,"steps":[${fail}]}}`,
          },
        ],
      },
    });
    await settle();
    const view = viewOf(store.getSnapshot());
    expect(view.phase).toBe("failed");
    expect(view.checklist.failing?.fix).toBe("Check the host name.");
    expect(view.buttons.map((each) => each.action)).toEqual(["copyDetails", "changeHost", "tryAgain"]);
    await store.perform("copyDetails");
    expect(host.ops("copy")).toEqual([
      {
        text: "host: leo@huge-blu\nname: lab\nreach: fail - no route (fix: Check the host name.)\ninstall: skip\ndaemon: skip\nupdate: skip\nharness: skip\npeer: skip\npeer-back: skip\nidentity: skip\napprovals: skip",
      },
    ]);
    host.status = { request: host.status.request };
    await store.perform("changeHost");
    await settle();
    expect(host.ops("cancel").length).toBe(1);
    expect(viewOf(store.getSnapshot()).phase).toBe("pick");
    expect(store.getSnapshot().destination).toBe("leo@huge-blu");
    expect(store.getSnapshot().name).toBe("lab");
  });

  test("a second press while an action is in flight sends nothing; Change Host drops a picked peer", async () => {
    const host = new FakeHost();
    host.status = { request: { seq: 1, mode: { kind: "add" }, destination: "hb" } };
    const { store } = await opened(host);
    const first = store.submit();
    expect(viewOf(store.getSnapshot()).buttons.at(-1)?.enabled).toBe(false);
    await store.submit();
    await first;
    expect(host.ops("add").length).toBe(1);

    const peer = new FakeHost();
    peer.candidateAnswers = [[candidate({ alreadyPeer: true, peer: "hb" })]];
    const second = await opened(peer);
    second.store.pick(candidate({ alreadyPeer: true, peer: "hb" }));
    await settle();
    peer.change({
      ...peer.status,
      run: { id: 1, host: "huge-blue.tail1.ts.net", name: "hb", outcome: "failed", events: [] },
    });
    await settle();
    peer.status = { request: peer.status.request };
    await second.store.perform("changeHost");
    await settle();
    expect(second.store.getSnapshot().picked).toBeUndefined();
  });

  test("Add stays off until a status read after the press lands, even when a change event supersedes it", async () => {
    // Status replies held by hand: the read after Add is superseded by a change event's read, so its
    // reply is dropped. Add must not come back on the old (pick) status and start a second run.
    class HeldStatusHost extends FakeHost {
      hold = false;
      held: (() => void)[] = [];
      override async call<T>(op: string, params?: unknown): Promise<T> {
        if (!this.hold || op !== "cmux.addMachine.status") return super.call<T>(op, params);
        const reply = structuredClone(this.status) as T;
        this.calls.push({ op, params });
        return new Promise<T>((resolve) => this.held.push(() => resolve(reply)));
      }
    }
    const host = new HeldStatusHost();
    host.status = { request: { seq: 1, mode: { kind: "add" }, destination: "hb" } };
    const { store } = await opened(host);
    host.hold = true;
    const press = store.submit();
    await settle();
    // The run starts; the host says so with a change event, whose read supersedes the press's own.
    host.change({
      ...host.status,
      run: { id: 1, host: "hb", name: "hb", outcome: "running", events: [] },
    });
    await settle();
    expect(host.held.length).toBe(2);
    host.held.shift()!();
    await press;
    await settle();
    expect(viewOf(store.getSnapshot()).buttons.find((each) => each.action === "add")?.enabled ?? false).toBe(false);
    await store.submit();
    expect(host.ops("add").length).toBe(1);
    host.held.shift()!();
    await settle();
    expect(store.getSnapshot().status?.run?.outcome).toBe("running");
    expect(store.getSnapshot().busy).toBe(false);
  });

  test("a changed field cannot add until its own parse answers", async () => {
    const host = new FakeHost();
    host.status = { request: { seq: 1, mode: { kind: "add" }, destination: "hb" } };
    const { store } = await opened(host);
    expect(viewOf(store.getSnapshot()).buttons.at(-1)?.enabled).toBe(true);
    store.setDestination("leo@other");
    expect(viewOf(store.getSnapshot()).buttons.at(-1)?.enabled).toBe(false);
    await settle();
    expect(store.getSnapshot().parsed?.shortName).toBe("other");
  });

  test("a card remounted over its run retries that run, not the opener's fields", async () => {
    // Opened on host A, edited to B and added; the person switched cards and came back while B ran.
    const host = new FakeHost();
    host.status = {
      request: { seq: 3, mode: { kind: "add" }, destination: "leo@host-a", name: "a" },
      run: {
        id: 1,
        host: "leo@host-b",
        name: "b",
        destination: "leo@host-b",
        outcome: "running",
        events: [],
      },
    };
    const { store } = await opened(host);
    expect(store.getSnapshot().destination).toBe("leo@host-b");
    expect(store.getSnapshot().name).toBe("b");
    host.change({ ...host.status, run: { ...host.status.run!, outcome: "failed" } });
    await settle();
    await store.perform("tryAgain");
    expect(host.ops("add")).toEqual([{ destination: "leo@host-b", name: "b" }]);

    // A picked agent peer's run retries as that peer.
    const peer = new FakeHost();
    peer.status = {
      request: { seq: 1, mode: { kind: "add" } },
      run: {
        id: 2,
        host: "huge-blue.tail1.ts.net",
        name: "hb",
        destination: "huge-blue.tail1.ts.net",
        peer: "hb",
        outcome: "failed",
        events: [],
      },
    };
    const second = await opened(peer);
    await second.store.perform("tryAgain");
    expect(peer.ops("add")).toEqual([{ destination: "huge-blue.tail1.ts.net", name: "hb", peer: "hb" }]);
  });

  test("Escape cancels a run and closes; with no Escape button the card just closes", async () => {
    const host = new FakeHost();
    host.status = {
      request: { seq: 1, mode: { kind: "add" } },
      run: { id: 1, host: "hb", name: "hb", outcome: "running", events: [{ kind: "start" }] },
    };
    const first = await opened(host);
    await first.store.escape();
    expect(host.ops("cancel").length).toBe(1);
    expect(first.closed()).toBe(1);

    const check = new FakeHost();
    check.status = {
      request: { seq: 1, mode: { kind: "check", host: "hb", machineID: "ssh-1" } },
      run: {
        id: 1,
        host: "hb",
        name: "hb",
        outcome: "failed",
        events: [{ kind: "start" }, { kind: "stop", detail: "" }],
      },
    };
    const second = await opened(check);
    await second.store.escape();
    expect(check.ops("cancel")).toEqual([]);
    expect(second.closed()).toBe(1);
    // Return there runs Fix.
    await second.store.submit();
    expect(check.ops("fix").length).toBe(1);
  });

  test("a reopen while a run goes keeps the fields; a new open resets them", async () => {
    const host = new FakeHost();
    host.status = { request: { seq: 1, mode: { kind: "add" }, destination: "hb" } };
    const { store } = await opened(host);
    store.setName("typed");
    host.change({ request: { seq: 1, mode: { kind: "add" }, destination: "hb" } });
    await settle();
    expect(store.getSnapshot().name).toBe("typed");
    host.change({ request: { seq: 2, mode: { kind: "add" } } });
    await settle();
    expect(store.getSnapshot().name).toBe("");
    expect(store.getSnapshot().destination).toBe("");
  });

  test("Open Workspace runs on the added machine and closes", async () => {
    const host = new FakeHost();
    host.status = {
      request: { seq: 1, mode: { kind: "add" } },
      run: { id: 1, host: "hb", name: "hb", outcome: "ready", events: [], machineID: "ssh-hb" },
    };
    const { store, closed } = await opened(host);
    await store.submit();
    expect(host.ops("openWorkspace").length).toBe(1);
    expect(closed()).toBe(1);
  });
});
