// l10n-allow-file: test fixture titles, not shipped UI.
// Every loading state in the agent pane ends (ui-state-fixes, round 5): an existing chat that is
// attaching shows "Loading conversation…" (not a blank transcript, not the hero), and an open that is
// refused or never answers ends in "Couldn't load this conversation." with Try Again; the `/` menu's
// "Loading commands…" ends after the same deadline in "Couldn't load commands." with Try Again.
// Timers are injected: nothing here waits on the wall clock.
import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { chat } from "../../gallery/fixtures/acpmux";
import { useChatLoad, CHAT_LOAD_REVEAL_MS } from "./ChatLoadState";
import { LOAD_DEADLINE_MS, useCommandsDeadline, useLoadDeadline, type Schedule } from "./loadDeadline";
import type { AcpmuxSnapshot } from "./model";

/// Timers a test fires by hand.
function manualTimers() {
  const armed: { fire: () => void; ms: number; live: boolean }[] = [];
  const schedule: Schedule = (fire, ms) => {
    const timer = { fire, ms, live: true };
    armed.push(timer);
    return () => void (timer.live = false);
  };
  const live = (ms?: number) => armed.filter((timer) => timer.live && (ms === undefined || timer.ms === ms));
  /// Fires every live timer of `ms`.
  const fire = (ms: number) =>
    act(() => {
      for (const timer of live(ms)) {
        timer.live = false;
        timer.fire();
      }
    });
  return { schedule, live, fire };
}

/// Renders `use` in a probe component; `rerender` gives it new input. Returns the latest result.
async function mount<P, R>(use: (props: P) => R, first: P) {
  const dom = new JSDOM("<!doctype html><main id=root></main>");
  const scope = globalThis as Record<string, unknown>;
  const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"] as const;
  const saved = new Map(keys.map((key) => [key, scope[key]]));
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  const seen: R[] = [];
  function Probe(props: { input: P }) {
    seen.push(use(props.input));
    return null;
  }
  const root: Root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<Probe input={first} />));
  return {
    latest: () => seen.at(-1)!,
    rerender: (input: P) => act(async () => root.render(<Probe input={input} />)),
    close: () => {
      act(() => root.unmount());
      for (const [key, value] of saved) {
        if (value === undefined) delete scope[key];
        else scope[key] = value;
      }
      dom.window.close();
    },
  };
}

test("a load deadline fires once per stretch, Try Again starts a fresh one, and a load that ends clears it", async () => {
  const timers = manualTimers();
  const probe = await mount(
    ({ loading, key }: { loading: boolean; key: string }) =>
      useLoadDeadline(loading, key, { schedule: timers.schedule }),
    { loading: true, key: "a" },
  );
  try {
    expect(probe.latest().timedOut).toBe(false);
    expect(timers.live(LOAD_DEADLINE_MS)).toHaveLength(1);
    await timers.fire(LOAD_DEADLINE_MS);
    expect(probe.latest().timedOut).toBe(true);
    // Try Again: loading again under a fresh deadline.
    await act(async () => probe.latest().restart());
    expect(probe.latest().timedOut).toBe(false);
    expect(timers.live(LOAD_DEADLINE_MS)).toHaveLength(1);
    await timers.fire(LOAD_DEADLINE_MS);
    expect(probe.latest().timedOut).toBe(true);
    // The load ends: no failure, no timer.
    await probe.rerender({ loading: false, key: "a" });
    expect(probe.latest().timedOut).toBe(false);
    expect(timers.live()).toHaveLength(0);
    // A new stretch of the same key does not inherit the last one's timeout.
    await probe.rerender({ loading: true, key: "a" });
    expect(probe.latest().timedOut).toBe(false);
    // Another key starts its own deadline.
    await timers.fire(LOAD_DEADLINE_MS);
    expect(probe.latest().timedOut).toBe(true);
    await probe.rerender({ loading: true, key: "b" });
    expect(probe.latest().timedOut).toBe(false);
    expect(timers.live(LOAD_DEADLINE_MS)).toHaveLength(1);
  } finally {
    probe.close();
  }
});

/// An existing chat whose summary has no turn count and whose attach has not answered.
function attaching(fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  const snapshot = chat([], { title: "Fix the flaky sidebar drag test", ...fields });
  if (snapshot.summary) delete snapshot.summary.turnCount;
  return snapshot;
}

test("an existing chat that is attaching shows Loading conversation…, then the error with Try Again after the deadline (M3)", async () => {
  const timers = manualTimers();
  let reopened = 0;
  const probe = await mount(
    ({ snapshot }: { snapshot: AcpmuxSnapshot }) =>
      useChatLoad(snapshot, false, () => void reopened++, {
        deadline: { schedule: timers.schedule },
        reveal: { schedule: timers.schedule },
      }),
    { snapshot: attaching() },
  );
  try {
    // A fast attach never flashes it: nothing until the reveal delay.
    expect(probe.latest().state).toBeUndefined();
    await timers.fire(CHAT_LOAD_REVEAL_MS);
    expect(probe.latest().state).toBe("loading");
    // It never answers: the error with Try Again, never loading forever.
    await timers.fire(LOAD_DEADLINE_MS);
    expect(probe.latest().state).toBe("failed");
    // Try Again opens the chat again and shows loading under a fresh deadline.
    await act(async () => probe.latest().retry());
    expect(reopened).toBe(1);
    expect(probe.latest().state).toBe("loading");
    expect(timers.live(LOAD_DEADLINE_MS)).toHaveLength(1);
    // The rows come: the chat, no load state.
    await probe.rerender({ snapshot: attaching({ rows: [{} as never], chatRead: true }) });
    expect(probe.latest().state).toBeUndefined();
    expect(timers.live()).toHaveLength(0);
    // A truly empty read: no load state (the hero is the new-chat branch, isNewChat).
    await probe.rerender({ snapshot: attaching({ chatRead: true }) });
    expect(probe.latest().state).toBeUndefined();
    // An open the client refused is the error at once.
    await probe.rerender({ snapshot: attaching({ connection: "failed" }) });
    expect(probe.latest().state).toBe("failed");
  } finally {
    probe.close();
  }
});

test("the / menu's Loading commands… ends in Couldn't load commands. with Try Again after the deadline (M7)", async () => {
  const timers = manualTimers();
  let retried = 0;
  const probe = await mount(
    ({ list }: { list: { commandsPending?: true; commandsFailed?: true } }) =>
      useCommandsDeadline(list, "chat-1", () => void retried++, { schedule: timers.schedule }),
    { list: { commandsPending: true } },
  );
  try {
    expect(probe.latest()).toMatchObject({ pending: true, failed: false, retry: undefined });
    await timers.fire(LOAD_DEADLINE_MS);
    expect(probe.latest()).toMatchObject({ pending: false, failed: true });
    expect(probe.latest().retry).toBeDefined();
    await act(async () => probe.latest().retry!());
    expect(retried).toBe(1);
    expect(probe.latest()).toMatchObject({ pending: true, failed: false });
    expect(timers.live(LOAD_DEADLINE_MS)).toHaveLength(1);
    // The list is read: neither loading nor failed, and no timer left.
    await probe.rerender({ list: {} });
    expect(probe.latest()).toMatchObject({ pending: false, failed: false, retry: undefined });
    expect(timers.live()).toHaveLength(0);
    // A read that failed is the failure at once, with Try Again.
    await probe.rerender({ list: { commandsFailed: true } });
    expect(probe.latest().failed).toBe(true);
    expect(probe.latest().retry).toBeDefined();
  } finally {
    probe.close();
  }
});
