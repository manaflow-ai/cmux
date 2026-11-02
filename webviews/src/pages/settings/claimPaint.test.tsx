// Leo, 2026-10-20: "the settings flicker is bad when you load it". The host shows Settings from the
// frame its paint report names (PagePaintProbe.swift; the pane keeps what it showed until then,
// PanePaintHold). The report waits for the page's gate (`__cmuxPaintAfter`). Settings opened with
// every control disabled at its schema default, then its values; and the host's cards (Spaces,
// Machines) appended after the first frame. Now the gate holds until the first screen is in, for a
// pooled page from its claim and for a page loaded fresh, so the first frame shown is the final one.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { act } = await import("react");
const { createMockClient } = await import("./mockProvider");
const { withMockTiming } = await import("./mockTiming");
const { mountSettingsPage } = await import("./mount");
const { PAINT_AFTER_NAME } = await import("../shared/paintGate");
const { PARKED_NAME } = await import("../shared/pageClient");

type SettingsClient = import("./ops").SettingsClient;

const scope = globalThis as Record<string, unknown>;
/// What the page has asked the host and not heard back yet: calls in flight, and stream events the
/// mock sent that the timing layer has not delivered to the page.
const traffic = { calls: 0, made: 0, sent: 0, delivered: 0 };
const quiet = () => traffic.made > 0 && traffic.calls === 0 && traffic.sent === traffic.delivered;
/// Counts the events the mock sends (`inner`) and the calls and events the page sees (`outer`).
function counted(client: SettingsClient, side: "inner" | "outer"): SettingsClient {
  return {
    async call<R>(op: string, params: unknown, opts?: { signal?: AbortSignal }) {
      if (side === "inner") return client.call<R>(op, params, opts);
      traffic.calls += 1;
      traffic.made += 1;
      try {
        return await client.call<R>(op, params, opts);
      } finally {
        traffic.calls -= 1;
      }
    },
    subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      if (side === "outer") traffic.calls += 1;
      traffic.made += 1;
      const subscribed = client.subscribe<E>(stream, (data, seq) => {
        traffic[side === "inner" ? "sent" : "delivered"] += 1;
        onEvent(data, seq);
      });
      if (side === "outer") void subscribed.finally(() => (traffic.calls -= 1));
      return subscribed;
    },
  };
}

let unmount: (() => void) | undefined;
afterEach(() => {
  Object.assign(traffic, { calls: 0, made: 0, sent: 0, delivered: 0 });
  act(() => unmount?.());
  unmount = undefined;
  document.body.replaceChildren();
  delete scope[PAINT_AFTER_NAME];
  delete scope[PARKED_NAME];
});

const DISABLED = ":disabled, [aria-disabled='true']";
const CONTROLS = "button, input, select, textarea, [role='switch'], [role='combobox'], [aria-disabled]";

/// What a frame shows: rows, setting rows whose controls are all disabled (a row waiting for its
/// value draws that way), and the page's groups. A disabled button beside enabled ones is the row's
/// state, not a wait: an ordered list's first Move Up and last Move Down (tabs.newTabWidgets.order,
/// #22903). Keep unrelated card actions out of this signal: they can be disabled for their own state.
function screen() {
  return {
    rows: document.querySelectorAll("[data-row-key]").length,
    disabled: [...document.querySelectorAll("[data-row-key] .row-control")].filter((control) => {
      const all = control.querySelectorAll(CONTROLS);
      return all.length > 0 && [...all].every((element) => element.matches(DISABLED));
    }).length,
    groups: document.querySelectorAll("section").length,
  };
}

/// Yields to the page until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  do {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  } while (!ready());
}

/// The screen once every call the page made is answered and every event the host sent has reached it.
async function settled() {
  await until(quiet, "every answer to reach the page");
  // React draws what the last answer changed.
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  expect(quiet()).toBe(true);
  return screen();
}

async function opened(search: string, claim: boolean) {
  const root = document.createElement("div");
  document.body.append(root);
  const client = counted(
    withMockTiming(counted(createMockClient().client, "inner"), new URLSearchParams(search)),
    "outer",
  );
  let mounted: Promise<() => void> | undefined;
  await act(async () => {
    mounted = mountSettingsPage(root, client);
  });
  void mounted!.then((stop) => (unmount = stop));
  if (claim) {
    // Parked in the pool until the host claims it (its first calls wait); then the host asks for a
    // paint report.
    await until(() => traffic.calls > 0, "the parked page's first calls");
    await act(async () => (scope.__cmuxSettingsClaim as () => void)());
  }
  const gate = scope[PAINT_AFTER_NAME] as Promise<unknown> | undefined;
  expect(gate).toBeDefined();
  await act(async () => await gate);
  return screen();
}

test("a pooled Settings page claimed by the host reports its paint once its first screen is in", async () => {
  const first = await opened("latency=20&parked", true);
  expect(first.rows).toBeGreaterThan(0);
  expect(first.disabled).toBe(0);
  expect(first).toEqual(await settled());
});

test("a Settings page loaded fresh reports its first paint once its first screen is in", async () => {
  const first = await opened("latency=20", false);
  expect(first.rows).toBeGreaterThan(0);
  expect(first.disabled).toBe(0);
  expect(first).toEqual(await settled());
});
