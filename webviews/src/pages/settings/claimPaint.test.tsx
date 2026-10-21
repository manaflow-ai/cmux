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

const scope = globalThis as Record<string, unknown>;
let unmount: (() => void) | undefined;
afterEach(() => {
  act(() => unmount?.());
  unmount = undefined;
  document.body.replaceChildren();
  delete scope[PAINT_AFTER_NAME];
  delete scope[PARKED_NAME];
});

/// What a frame shows: rows, disabled controls and the page's groups.
function screen() {
  return {
    rows: document.querySelectorAll("[data-row-key]").length,
    disabled: document.querySelectorAll(".row-control :disabled, .row-control [aria-disabled='true']").length,
    groups: document.querySelectorAll("section").length,
  };
}

async function settled() {
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 300)));
  return screen();
}

async function opened(search: string, claim: boolean) {
  const root = document.createElement("div");
  document.body.append(root);
  const client = withMockTiming(createMockClient().client, new URLSearchParams(search));
  let mounted: Promise<() => void> | undefined;
  await act(async () => {
    mounted = mountSettingsPage(root, client);
  });
  void mounted!.then((stop) => (unmount = stop));
  if (claim) {
    // Parked in the pool until the host claims it; then the host asks for a paint report.
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 50)));
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
