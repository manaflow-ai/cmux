// l10n-allow-file: deterministic recovery fixtures.
// Opening a Cloud chat whose machine is paused wakes it with no click (cloudWake.ts `cloudOpenWakes`,
// useCloudChatRecovery `wake`): the passive `cloudMachine.prewarm`, never the gesture-taking attach;
// the card says it is waking with no Resume machine; a refused wake leaves the paused card's button,
// whose click runs the person's attach.
import { afterEach, beforeEach, expect, test } from "bun:test";
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
beforeEach(async () => {
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
});
afterEach(async () => {
  await act(async () => root.unmount());
  mount.remove();
  await teardownDom(saved, { window: dom.window, scope });
});

const asleep = {
  cloud: true,
  chat: "chat-1",
  linkUp: false,
  paused: true,
  unavailable: true,
  asleep: true,
  woke: undefined,
  shown: true,
  deleted: false,
  watching: false,
};

test("opening a shown Cloud chat whose machine is paused wakes it, once per sleep", async () => {
  const { cloudOpenWakes } = await import("../src/agent-session/acpmux/cloudWake");
  expect(cloudOpenWakes(asleep)).toBe("chat-1");
  // Already woken in this stretch (by the open or a keystroke): not again.
  expect(cloudOpenWakes({ ...asleep, woke: "chat-1" })).toBeUndefined();
  // A pane no one sees, a deleted machine, a watched chat, a machine not read as asleep, a local chat.
  expect(cloudOpenWakes({ ...asleep, shown: false })).toBeUndefined();
  expect(cloudOpenWakes({ ...asleep, deleted: true })).toBeUndefined();
  expect(cloudOpenWakes({ ...asleep, watching: true })).toBeUndefined();
  expect(cloudOpenWakes({ ...asleep, asleep: false })).toBeUndefined();
  expect(cloudOpenWakes({ ...asleep, cloud: false })).toBeUndefined();
  // A live link to a machine the list read as paused (a stale read): it sends as usual.
  expect(cloudOpenWakes({ ...asleep, linkUp: true, paused: false, unavailable: false })).toBeUndefined();
});

async function openFixture(prewarm: "ok" | "refused") {
  const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
  const { ChatUnavailableState } = await import("../src/agent-session/acpmux/ChatUnavailableState");
  const { cloudChatUnavailable } = await import("../src/agent-session/acpmux/cloudChatRecovery");
  const { useEffect, useRef } = await import("react");
  const calls: string[] = [];
  const box = { stage: "paused" as string };
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: ({ method }: { method: string }) => {
            calls.push(method);
            if (method === "cloudMachine.prewarm") {
              if (prewarm === "refused") return { ok: false, error: { code: "unavailable", retryable: false } };
              // The list still reads it paused while it starts.
              return { ok: true, value: {} };
            }
            if (method === "cloudMachine.attach") return { ok: true, value: {} };
            return {
              ok: true,
              value: {
                signedIn: true,
                loaded: true,
                complete: true,
                account: ["user", null],
                machines: [{ id: "vm-demo", name: "Demo machine", stage: box.stage }],
              },
            };
          },
        },
      },
    },
  });
  const noop = () => {};
  // Stable, as the App's `recheckCloudChat` (useCallback) is: a new one each render reruns the read.
  const recheck = async () => {};
  function Recovery() {
    const recovery = useCloudChatRecovery({
      cloud: { id: "vm-demo", account: ["user", null] },
      session: "chat-demo",
      active: true,
      recheck,
    });
    // The App's open wake: once per sleep (App's `cloudTypeWoke`), when the recovery reads it paused.
    const woke = useRef(false);
    const wake = useRef(recovery.wake);
    wake.current = recovery.wake;
    useEffect(() => {
      if (recovery.state !== "paused" || woke.current) return;
      woke.current = true;
      wake.current();
    }, [recovery.state]);
    return (
      <>
        <ChatUnavailableState
          unavailable={cloudChatUnavailable({ reason: "offline" }, recovery.state, "Demo machine")}
          onResumeMachine={recovery.resume}
          noteDelayMs={0}
          onRemove={noop}
          onReconnect={recovery.refresh}
          resuming={recovery.resuming}
          waking={recovery.waking}
          {...(recovery.error ? { error: recovery.error } : {})}
        />
        <span data-action="wake-state">
          {JSON.stringify({ waking: recovery.waking, refused: recovery.wakeRefused, error: recovery.error ?? null })}
        </span>
      </>
    );
  }
  await act(async () => root.render(<Recovery />));
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return {
    calls,
    button: () => mount.querySelector<HTMLButtonElement>('[data-action="resumeMachine"]'),
    title: () => mount.querySelector(".acpmux-unavailable-title")?.textContent,
    state: () => JSON.parse(mount.querySelector('[data-action="wake-state"]')!.textContent!),
  };
}

test.serial("the open wake is the passive prewarm, and the card offers no Resume machine meanwhile", async () => {
  const fixture = await openFixture("ok");
  expect(fixture.calls.filter((method) => method === "cloudMachine.prewarm")).toHaveLength(1);
  expect(fixture.calls).not.toContain("cloudMachine.attach");
  expect(fixture.state()).toEqual({ waking: true, refused: false, error: null });
  expect(fixture.button()).toBeNull();
  expect(fixture.title()).toBe("Waking the machine…");
  await act(async () => root.render(null));
});

test.serial("a refused open wake leaves the paused card, and its click runs the person's attach", async () => {
  const fixture = await openFixture("refused");
  expect(fixture.calls.filter((method) => method === "cloudMachine.prewarm")).toHaveLength(1);
  expect(fixture.state()).toEqual({ waking: false, refused: true, error: null });
  expect(fixture.title()).toBe("Machine is paused");
  expect(fixture.button()?.disabled).toBe(false);
  await act(async () => fixture.button()!.click());
  expect(fixture.calls.filter((method) => method === "cloudMachine.attach")).toHaveLength(1);
  // The refused wake is not run again by the click, nor by the reads that follow.
  expect(fixture.calls.filter((method) => method === "cloudMachine.prewarm")).toHaveLength(1);
  await act(async () => root.render(null));
});
