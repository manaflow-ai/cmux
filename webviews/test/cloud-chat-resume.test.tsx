// l10n-allow-file: deterministic recovery fixtures.
import { afterEach, beforeEach, expect, jest, setSystemTime, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  dom.window.close();
  for (const [key, present, value] of saved) {
    if (present) scope[key] = value;
    else delete scope[key];
  }
  jest.useRealTimers();
  setSystemTime();
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

// Stable callbacks keep fixture rerenders from restarting the hook's deadline.
async function deadlineFixture(pending: "inventory" | "recheck") {
  const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
  let reads = 0;
  let rechecks = 0;
  const hung = new Promise<void>(() => {});
  const recheck = () => {
    rechecks += 1;
    return hung;
  };
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: ({ method }: { method: string }) => {
            if (method === "cloudMachine.attach") return { ok: true, value: {} };
            if (method === "cloudMachine.list") {
              reads += 1;
              if (pending === "inventory") return hung;
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
  function Recovery({ session }: { session: string }) {
    const recovery = useCloudChatRecovery({
      cloud: { id: "vm-demo", account: ["user", null] },
      session,
      active: true,
      recheck,
    });
    return (
      <div>
        <button data-action="deadline-wake" onClick={recovery.resume}>
          Resume
        </button>
        <span data-action="deadline-state">
          {JSON.stringify({ resuming: recovery.resuming, error: recovery.error })}
        </span>
      </div>
    );
  }
  return {
    render: (session: string) => act(async () => root.render(<Recovery session={session} />)),
    wake: () => act(async () => mount.querySelector<HTMLButtonElement>('[data-action="deadline-wake"]')!.click()),
    state: () => JSON.parse(mount.querySelector('[data-action="deadline-state"]')!.textContent!),
    reads: () => reads,
    rechecks: () => rechecks,
  };
}

for (const pending of ["inventory", "recheck"] as const) {
  test.serial(`a hung ${pending} fails at the original recovery deadline`, async () => {
    const fixture = await deadlineFixture(pending);
    jest.useFakeTimers({ now: 0 });
    try {
      await fixture.render("old");
      await fixture.wake();
      expect(fixture.reads()).toBe(1);
      expect(fixture.rechecks()).toBe(pending === "recheck" ? 1 : 0);
      expect(fixture.state()).toEqual({ resuming: true });
      await act(async () => {
        jest.advanceTimersByTime(59_999);
      });
      expect(fixture.state()).toEqual({ resuming: true });
      await act(async () => {
        jest.advanceTimersByTime(1);
      });
      expect(fixture.state().resuming).toBe(false);
      expect(fixture.state().error).toBeDefined();
      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
      await act(async () => root.render(null));
    }
  });

  test.serial(`switching chats cancels a hung ${pending} without failing the new recovery`, async () => {
    const fixture = await deadlineFixture(pending);
    jest.useFakeTimers({ now: 0 });
    try {
      await fixture.render("old");
      await fixture.wake();
      expect(fixture.reads()).toBe(1);
      expect(jest.getTimerCount()).toBe(1);
      await act(async () => {
        jest.advanceTimersByTime(30_000);
      });
      await fixture.render("new");
      expect(jest.getTimerCount()).toBe(0);
      await fixture.wake();
      expect(fixture.state()).toEqual({ resuming: true });
      // The old deadline expires now; the new chat still has thirty seconds.
      await act(async () => {
        jest.advanceTimersByTime(30_000);
      });
      expect(fixture.state()).toEqual({ resuming: true });
      expect(jest.getTimerCount()).toBe(1);
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

test.serial("a timed-out attach's late rejection leaves a newer resume running", async () => {
  const fixture = await attachFixture();
  jest.useFakeTimers({ now: 0 });
  await fixture.render();
  await act(async () => fixture.button()!.click());
  await act(async () => {
    jest.advanceTimersByTime(60_000);
  });
  expect(fixture.state().resuming).toBe(false);
  expect(fixture.state().error).toBeDefined();
  expect(jest.getTimerCount()).toBe(0);
  await act(async () => fixture.button()!.click());
  expect(fixture.rejects).toHaveLength(2);
  expect(fixture.state()).toEqual({ resuming: true });
  await act(async () => fixture.rejects[0]!(new Error("old attach failed")));
  expect(fixture.state()).toEqual({ resuming: true });
  expect(fixture.button()?.disabled).toBe(true);
  expect(jest.getTimerCount()).toBe(1);
  // The current attach still owns its failure and releases the retry button.
  await act(async () => fixture.rejects[1]!(new Error("current attach failed")));
  expect(fixture.state().resuming).toBe(false);
  expect(fixture.state().error).toBeDefined();
  expect(fixture.button()?.disabled).toBe(false);
  expect(jest.getTimerCount()).toBe(0);
});
