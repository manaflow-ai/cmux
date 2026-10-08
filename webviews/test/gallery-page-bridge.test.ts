import { expect, test } from "bun:test";
import { installDom } from "../src/pages/settings/testDom";
import { installMockHost } from "./latency/mock-host";
import { createPageClient } from "../src/pages/shared/pageClient";
import { iconPickerFixtureOps } from "../src/gallery/frame/iconPicker";
import iconPicker from "../src/pages/icon-picker/icon-picker.gallery";

test("icon picker session arrives after the real bridge subscription is acknowledged", async () => {
  const restore = installDom();
  const state = iconPicker.variants.emoji!;
  const host = installMockHost(iconPickerFixtureOps(state), ["cmux.iconPicker.session"], {
    "cmux.iconPicker.session": state.session,
  });
  host.delayMs = 0;
  const scope = globalThis as unknown as { webkit?: unknown };
  const savedWebkit = scope.webkit;
  scope.webkit = (window as unknown as { webkit: unknown }).webkit;
  const client = createPageClient()!;
  let stop: (() => void) | undefined;
  try {
    const event = Promise.withResolvers<unknown>();
    stop = await client.subscribe("cmux.iconPicker.session", event.resolve);
    expect(await event.promise).toEqual(state.session);
    await host.initialEventsDelivered;
    // The variant's saved prefs (Frequently Used) come back through the real prefs operation.
    expect(await client.call("cmux.iconPicker.prefs.load", {})).toEqual(state.prefs);
  } finally {
    stop?.();
    scope.webkit = savedWebkit;
    restore();
  }
});

test("icon asset errors and loading travel through the real asset operation", async () => {
  const errors = iconPickerFixtureOps(iconPicker.variants.error!);
  expect(() => errors["cmux.iconPicker.asset.fromURL"]!({}, {})).toThrow("Sample asset download refused");
  const loading = iconPickerFixtureOps(iconPicker.variants.loading!);
  let completed = false;
  void Promise.resolve(loading["cmux.iconPicker.asset.fromURL"]!({}, {})).then(() => {
    completed = true;
  });
  await Promise.resolve();
  expect(completed).toBe(false);
});
