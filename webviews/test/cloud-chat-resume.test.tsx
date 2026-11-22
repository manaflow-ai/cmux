// l10n-allow-file: deterministic recovery fixtures.
import { afterEach, beforeEach, expect, jest, setSystemTime, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const scope = globalThis as Record<string, unknown>;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root;
let mount: HTMLElement;
async function setup() {
  dom = new JSDOM("<!doctype html><div id='root'></div>", { url: "https://cmux.test" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  mount = dom.window.document.getElementById("root")!;
  root = (await import("react-dom/client")).createRoot(mount);
}
beforeEach(setup);
afterEach(async () => {
  await act(async () => root.unmount());
  mount.remove();
  jest.useRealTimers();
  setSystemTime();
  await teardownDom(saved, { window: dom.window, scope });
});

test.serial("Resume uses native attach, then rereads the missing chat; disposal stops recovery", async () => {
  const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
  const { ChatUnavailableState } = await import("../src/agent-session/acpmux/ChatUnavailableState");
  const { cloudChatUnavailable } = await import("../src/agent-session/acpmux/cloudChatRecovery");
  const calls: string[] = [];
  let stage = "paused";
  let failRead = true;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: ({ method }: { method: string }) => {
            calls.push(method);
            if (method === "cloudMachine.recoveryList" && failRead) {
              failRead = false;
              return { ok: false, error: { code: "network" } };
            }
            if (method === "cloudMachine.attach") {
              stage = "connecting";
              return { ok: true, value: {} };
            }
            return {
              ok: true,
              value: {
                signedIn: true,
                loaded: true,
                complete: true,
                account: ["user", null],
                machines: [{ id: "vm-demo", name: "Demo machine", stage }],
              },
            };
          },
        },
      },
    },
  });
  let opened = false;
  const recheck = async () => {
    opened = stage === "connecting";
  };
  const noop = () => {};
  function Recovery() {
    const recovery = useCloudChatRecovery({
      cloud: { id: "vm-demo", account: ["user", null] },
      session: "chat-demo",
      active: true,
      recheck,
    });
    return (
      <ChatUnavailableState
        unavailable={cloudChatUnavailable({ reason: "offline" }, recovery.state, "Demo machine")}
        onResumeMachine={recovery.resume}
        // The settled card: no RESUME_NOTE_DELAY_MS wait (afterDelay.ts).
        noteDelayMs={0}
        onRemove={noop}
        onReconnect={recovery.refresh}
        resuming={recovery.resuming}
      />
    );
  }
  await act(async () => root.render(<Recovery />));
  const retry = mount.querySelector<HTMLButtonElement>('[data-action="reconnect"]');
  expect(retry).not.toBeNull();
  await act(async () => retry!.click());
  expect(calls.filter((method) => method === "cloudMachine.recoveryList")).toHaveLength(2);
  const button = mount.querySelector<HTMLButtonElement>('[data-action="resumeMachine"]');
  expect(button).not.toBeNull();
  await act(async () => button!.click());
  expect(calls.filter((method) => method === "cloudMachine.attach")).toHaveLength(1);
  expect(calls).not.toContain("cloudMachine.open");
  expect(opened).toBe(true);
  await act(async () => root.render(null));
});

test.serial(
  "Resume retries incomplete reads and refuses a same-tick double attach",
  async () => {
    const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
    let listReads = 0;
    let attaches = 0;
    let rechecks = 0;
    Object.assign(dom.window, {
      webkit: {
        messageHandlers: {
          agentSession: {
            postMessage: ({ method }: { method: string }) => {
              if (method === "cloudMachine.attach") {
                attaches += 1;
                return { ok: true, value: {} };
              }
              if (method === "cloudMachine.list") {
                listReads += 1;
                // The wake is accepted, but first the account list is incomplete,
                // then one request fails. Neither is evidence that the VM is gone.
                if (listReads === 1) return { ok: true, value: { signedIn: true, loaded: false, machines: [] } };
                if (listReads === 2) return { ok: false, error: { code: "network" } };
                return {
                  ok: true,
                  value: {
                    signedIn: true,
                    loaded: true,
                    complete: true,
                    account: ["user", null],
                    machines: [{ id: "vm-demo", name: "Demo machine", stage: "connecting" }],
                  },
                };
              }
              return {
                ok: true,
                value: {
                  signedIn: true,
                  loaded: true,
                  complete: true,
                  account: ["user", null],
                  machines: [{ id: "vm-demo", name: "Demo machine", stage: "paused" }],
                },
              };
            },
          },
        },
      },
    });
    const recheck = async () => {
      rechecks += 1;
    };
    function Recovery() {
      const recovery = useCloudChatRecovery({
        cloud: { id: "vm-demo", account: ["user", null] },
        session: "chat-demo",
        active: true,
        recheck,
      });
      return (
        <div>
          <button
            data-action="test-wake"
            onClick={() => {
              recovery.resume();
              recovery.resume();
            }}
          >
            Resume
          </button>
          <span data-action="test-state">
            {JSON.stringify({
              state: recovery.state,
              resuming: recovery.resuming,
              error: recovery.error,
            })}
          </span>
        </div>
      );
    }
    await act(async () => root.render(<Recovery />));
    expect(mount.querySelector('[data-action="test-state"]')?.textContent).toContain('"state":"paused"');
    await act(async () => mount.querySelector<HTMLButtonElement>('[data-action="test-wake"]')!.click());
    expect(listReads).toBe(1);
    expect(attaches).toBe(1);
    expect(mount.querySelector('[data-action="test-state"]')?.textContent).toContain('"resuming":true');

    await act(async () => {
      // fixed-wait: exercise two real 1 s recovery intervals so both transient reads are retried.
      await new Promise((resolve) => setTimeout(resolve, 2_400));
    });
    expect(listReads).toBeGreaterThanOrEqual(3);
    expect(rechecks).toBeGreaterThanOrEqual(1);
    expect(attaches).toBe(1);
    expect(mount.querySelector('[data-action="test-state"]')?.textContent).toContain('"state":"live"');
    expect(mount.querySelector('[data-action="test-state"]')?.textContent).toContain('"resuming":true');
    expect(mount.querySelector('[data-action="test-state"]')?.textContent).not.toContain("resumeFailed");
    await act(async () => root.render(null));
  },
  10_000,
);

test.serial(
  "a nonretryable inventory refusal ends recovery without repeated polls",
  async () => {
    const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
    let listReads = 0;
    let attaches = 0;
    Object.assign(dom.window, {
      webkit: {
        messageHandlers: {
          agentSession: {
            postMessage: ({ method }: { method: string }) => {
              if (method === "cloudMachine.attach") {
                attaches += 1;
                return { ok: true, value: {} };
              }
              if (method === "cloudMachine.list") {
                listReads += 1;
                return { ok: false, error: { code: "auth.forbidden", retryable: false, origin: "native" } };
              }
              return {
                ok: true,
                value: {
                  signedIn: true,
                  loaded: true,
                  complete: true,
                  account: ["user", null],
                  machines: [{ id: "vm-demo", name: "Demo machine", stage: "paused" }],
                },
              };
            },
          },
        },
      },
    });
    const recheck = async () => {};
    function Recovery() {
      const recovery = useCloudChatRecovery({
        cloud: { id: "vm-demo", account: ["user", null] },
        session: "chat-demo",
        active: true,
        recheck,
      });
      return (
        <div>
          <button data-action="refused-wake" onClick={recovery.resume}>
            Resume
          </button>
          <span data-action="refused-state">
            {JSON.stringify({
              resuming: recovery.resuming,
              error: recovery.error,
            })}
          </span>
        </div>
      );
    }
    await act(async () => root.render(<Recovery />));
    await act(async () => mount.querySelector<HTMLButtonElement>('[data-action="refused-wake"]')!.click());
    expect(attaches).toBe(1);
    expect(listReads).toBe(1);
    const state = mount.querySelector('[data-action="refused-state"]')?.textContent ?? "";
    expect(state).toContain('"resuming":false');
    expect(state).toContain('"error":');
    await act(async () => root.render(null));
  },
  10_000,
);

// #35206 removed the resume's 60 s deadline: a live native bridge owns each request's lifetime.
// A resume now waits until the request answers (the answer continues the resume), the native
// call fails for good (non-retryable: the daemon is gone), or the person leaves the chat (switch,
// deactivate, unmount). Here the `pending` request is held until the test answers it or fails it.
// Stable callbacks keep fixture rerenders from restarting the hook's read.
const GONE = { ok: false, error: { code: "daemon.gone", retryable: false, origin: "native" } };

async function waitFixture(pending: "inventory" | "recheck") {
  const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
  const { NativeError } = await import("../src/agent-session/acpmux/nativeError");
  let reads = 0;
  let rechecks = 0;
  // One entry per held request, in order: answer it (or fail it) to end that wait.
  const held: { answer(): void; fail(): void }[] = [];
  const inventory = {
    ok: true,
    value: {
      signedIn: true,
      loaded: true,
      complete: true,
      account: ["user", null],
      machines: [{ id: "vm-demo", name: "Demo machine", stage: "paused" }],
    },
  };
  const recheck = () => {
    rechecks += 1;
    if (pending !== "recheck") return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      held.push({
        answer: () => resolve(),
        fail: () => reject(new NativeError({ code: GONE.error.code, retryable: false, origin: "native" })),
      });
    });
  };
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: ({ method }: { method: string }) => {
            if (method === "cloudMachine.attach") return { ok: true, value: {} };
            if (method === "cloudMachine.list") {
              reads += 1;
              if (pending === "inventory")
                return new Promise((resolve) => {
                  held.push({ answer: () => resolve(inventory), fail: () => resolve(GONE) });
                });
            }
            return inventory;
          },
        },
      },
    },
  });
  function Recovery({ session }: { session: string }) {
    const recovery = useCloudChatRecovery({
      cloud: { id: "vm-demo", account: ["user", null] },
      session,
      active: true,
      recheck,
    });
    return (
      <div>
        <button data-action="wait-wake" onClick={recovery.resume}>
          Resume
        </button>
        <span data-action="wait-state">{JSON.stringify({ resuming: recovery.resuming, error: recovery.error })}</span>
      </div>
    );
  }
  return {
    render: (session: string) => act(async () => root.render(<Recovery session={session} />)),
    wake: () => act(async () => mount.querySelector<HTMLButtonElement>('[data-action="wait-wake"]')!.click()),
    state: () => JSON.parse(mount.querySelector('[data-action="wait-state"]')!.textContent!),
    reads: () => reads,
    rechecks: () => rechecks,
    held,
  };
}

for (const pending of ["inventory", "recheck"] as const) {
  test.serial(`a slow ${pending} keeps the resume waiting past the old 60 s deadline until it answers`, async () => {
    const fixture = await waitFixture(pending);
    jest.useFakeTimers({ now: 0 });
    try {
      await fixture.render("old");
      await fixture.wake();
      expect(fixture.held).toHaveLength(1);
      expect(fixture.reads()).toBe(1);
      expect(fixture.rechecks()).toBe(pending === "recheck" ? 1 : 0);
      // Ten minutes, ten times the old deadline: no timer fails the resume and no read is repeated
      // over the one in flight. A request that never answers while the bridge stays alive keeps
      // the resume waiting until the person leaves the chat; #35206 states no other end for it.
      await act(async () => {
        jest.advanceTimersByTime(600_000);
      });
      expect(fixture.state()).toEqual({ resuming: true });
      expect(jest.getTimerCount()).toBe(0);
      expect(fixture.reads()).toBe(1);
      // The answer ends the wait: the resume goes on (the inventory's answer runs the recheck)
      // and reads again a second later.
      await act(async () => fixture.held[0]!.answer());
      expect(fixture.rechecks()).toBe(1);
      expect(fixture.state()).toEqual({ resuming: true });
      expect(jest.getTimerCount()).toBe(1);
      await act(async () => {
        jest.advanceTimersByTime(1_000);
      });
      expect(fixture.reads()).toBe(2);
    } finally {
      jest.useRealTimers();
      await act(async () => root.render(null));
    }
  });

  test.serial(`a slow ${pending} whose daemon is gone fails the resume`, async () => {
    const fixture = await waitFixture(pending);
    jest.useFakeTimers({ now: 0 });
    try {
      await fixture.render("old");
      await fixture.wake();
      await act(async () => {
        jest.advanceTimersByTime(600_000);
      });
      expect(fixture.state()).toEqual({ resuming: true });
      // A non-retryable native failure ends the wait with the error, and nothing reads again.
      await act(async () => fixture.held[0]!.fail());
      expect(fixture.state().resuming).toBe(false);
      expect(fixture.state().error).toBeDefined();
      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
      await act(async () => root.render(null));
    }
  });

  test.serial(`switching chats cancels a hung ${pending} without failing the new recovery`, async () => {
    const fixture = await waitFixture(pending);
    jest.useFakeTimers({ now: 0 });
    try {
      await fixture.render("old");
      await fixture.wake();
      expect(fixture.held).toHaveLength(1);
      // The person leaves the chat: the old wait ends with no error and no timer left behind.
      await fixture.render("new");
      expect(fixture.state()).toEqual({ resuming: false });
      expect(jest.getTimerCount()).toBe(0);
      await fixture.wake();
      expect(fixture.state()).toEqual({ resuming: true });
      const reads = fixture.reads();
      const rechecks = fixture.rechecks();
      // The old chat's request answers late, then would fail for good: neither touches the new
      // recovery, and neither starts a read or a recheck for the chat that was left.
      await act(async () => fixture.held[0]!.answer());
      await act(async () => fixture.held[0]!.fail());
      expect(fixture.state()).toEqual({ resuming: true });
      expect(fixture.reads()).toBe(reads);
      expect(fixture.rechecks()).toBe(rechecks);
      expect(jest.getTimerCount()).toBe(0);
      // Unmount ends the new wait too.
      await act(async () => root.render(null));
      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
      await act(async () => root.render(null));
    }
  });
}

test.serial(
  "an old chat's late inventory refusal leaves the new recovery running",
  async () => {
    const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
    let refuseOldRead!: (reply: unknown) => void;
    const oldRead = new Promise((resolve) => {
      refuseOldRead = resolve;
    });
    let listReads = 0;
    let rechecks = 0;
    const inventory = {
      ok: true,
      value: {
        signedIn: true,
        loaded: true,
        complete: true,
        account: ["user", null],
        machines: [
          { id: "vm-old", name: "Old machine", stage: "paused" },
          { id: "vm-new", name: "New machine", stage: "paused" },
        ],
      },
    };
    Object.assign(dom.window, {
      webkit: {
        messageHandlers: {
          agentSession: {
            postMessage: ({ method }: { method: string }) => {
              if (method === "cloudMachine.attach") return { ok: true, value: {} };
              if (method === "cloudMachine.list" && ++listReads === 1) return oldRead;
              return inventory;
            },
          },
        },
      },
    });
    const recheck = async () => {
      rechecks += 1;
    };
    function Recovery({ machine }: { machine: string }) {
      const recovery = useCloudChatRecovery({
        cloud: { id: machine, account: ["user", null] },
        session: `chat-${machine}`,
        active: true,
        recheck,
      });
      return (
        <div>
          <button data-action="switch-wake" onClick={recovery.resume}>
            Resume
          </button>
          <span data-action="switch-state">
            {JSON.stringify({
              state: recovery.state,
              resuming: recovery.resuming,
              error: recovery.error,
            })}
          </span>
        </div>
      );
    }
    const wake = () => mount.querySelector<HTMLButtonElement>('[data-action="switch-wake"]')!.click();
    const state = () => JSON.parse(mount.querySelector('[data-action="switch-state"]')!.textContent!);
    try {
      await act(async () => root.render(<Recovery machine="vm-old" />));
      await act(async () => wake());
      expect(listReads).toBe(1);
      await act(async () => root.render(<Recovery machine="vm-new" />));
      await act(async () => wake());
      expect(state()).toEqual({ state: "paused", resuming: true });
      const readsBeforeRefusal = listReads;
      const rechecksBeforeRefusal = rechecks;
      await act(async () => {
        refuseOldRead({ ok: false, error: { code: "auth.forbidden", retryable: false, origin: "native" } });
      });
      expect(state()).toEqual({ state: "paused", resuming: true });
      await act(async () => {
        // fixed-wait: the regression can cancel the new chat's real 1 s retry timer.
        await new Promise((resolve) => setTimeout(resolve, 1_200));
      });
      expect(listReads).toBeGreaterThan(readsBeforeRefusal);
      expect(rechecks).toBeGreaterThan(rechecksBeforeRefusal);
      expect(state()).toEqual({ state: "paused", resuming: true });
    } finally {
      await act(async () => root.render(null));
    }
  },
  10_000,
);

async function attachFixture() {
  const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
  const { ChatUnavailableState } = await import("../src/agent-session/acpmux/ChatUnavailableState");
  const { cloudChatUnavailable } = await import("../src/agent-session/acpmux/cloudChatRecovery");
  const rejects: ((cause: Error) => void)[] = [];
  const list = { gone: false };
  const hung = new Promise<void>(() => {});
  const recheck = () => hung;
  const noop = () => {};
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: ({ method }: { method: string }) => {
            if (method === "cloudMachine.attach") {
              return new Promise((_, reject) => rejects.push(reject));
            }
            if (method === "cloudMachine.list" && list.gone) return GONE;
            return {
              ok: true,
              value: {
                signedIn: true,
                loaded: true,
                complete: true,
                account: ["user", null],
                machines: [{ id: "vm-demo", name: "Demo machine", stage: rejects.length ? "failed" : "paused" }],
              },
            };
          },
        },
      },
    },
  });
  function Recovery() {
    const recovery = useCloudChatRecovery({
      cloud: { id: "vm-demo", account: ["user", null] },
      session: "chat-demo",
      active: true,
      recheck,
    });
    return (
      <>
        <ChatUnavailableState
          unavailable={cloudChatUnavailable({ reason: "offline" }, recovery.state, "Demo machine")}
          onResumeMachine={recovery.resume}
          // The settled card: no RESUME_NOTE_DELAY_MS wait (afterDelay.ts).
          noteDelayMs={0}
          onRemove={noop}
          onReconnect={recovery.refresh}
          resuming={recovery.resuming}
          error={recovery.error}
        />
        <span data-action="attach-state">{JSON.stringify({ resuming: recovery.resuming, error: recovery.error })}</span>
      </>
    );
  }
  return {
    render: () => act(async () => root.render(<Recovery />)),
    button: () => mount.querySelector<HTMLButtonElement>('[data-action="resumeMachine"]'),
    state: () => JSON.parse(mount.querySelector('[data-action="attach-state"]')!.textContent!),
    rejects,
    list,
  };
}

test.serial("a failed resume still offers Resume machine and sends attach again", async () => {
  const fixture = await attachFixture();
  await fixture.render();
  await act(async () => fixture.button()!.click());
  expect(fixture.rejects).toHaveLength(1);
  // A failed inventory stage alone must not cancel the pending attach.
  expect(fixture.state()).toEqual({ resuming: true });
  await act(async () => fixture.rejects[0]!(new Error("resume failed")));
  expect(fixture.state().resuming).toBe(false);
  expect(fixture.state().error).toBeDefined();
  expect(fixture.button()?.textContent).toBe("Resume machine");
  expect(fixture.button()?.disabled).toBe(false);
  expect(mount.querySelector('[data-action="reconnect"]')).toBeNull();
  await act(async () => fixture.button()!.click());
  expect(fixture.rejects).toHaveLength(2);
  expect(fixture.state()).toEqual({ resuming: true });
});

test.serial(
  "an attach left pending when its resume ends: its late rejection leaves a newer resume running",
  async () => {
    const fixture = await attachFixture();
    await fixture.render();
    // The daemon is gone: the resume's account read fails for good while its attach is still pending.
    fixture.list.gone = true;
    await act(async () => fixture.button()!.click());
    expect(fixture.rejects).toHaveLength(1);
    expect(fixture.state().resuming).toBe(false);
    expect(fixture.state().error).toBeDefined();
    expect(fixture.button()?.disabled).toBe(false);
    // The daemon is back and the person resumes again.
    fixture.list.gone = false;
    await act(async () => fixture.button()!.click());
    expect(fixture.rejects).toHaveLength(2);
    expect(fixture.state()).toEqual({ resuming: true });
    await act(async () => fixture.rejects[0]!(new Error("old attach failed")));
    expect(fixture.state()).toEqual({ resuming: true });
    expect(fixture.button()?.disabled).toBe(true);
    // The current attach still owns its failure and releases the retry button.
    await act(async () => fixture.rejects[1]!(new Error("current attach failed")));
    expect(fixture.state().resuming).toBe(false);
    expect(fixture.state().error).toBeDefined();
    expect(fixture.button()?.disabled).toBe(false);
    await act(async () => root.render(null));
  },
);
