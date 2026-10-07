import { expect, test } from "bun:test";
import { installDom } from "../src/pages/settings/testDom";
import { installMockHost } from "./latency/mock-host";
import { createPageClient } from "../src/pages/shared/pageClient";
import iconPicker from "../src/pages/icon-picker/icon-picker.gallery";

test("icon picker session arrives after the real bridge subscription is acknowledged", async () => {
  const restore = installDom();
  const state = iconPicker.variants.emoji!;
  const host = installMockHost({ "cmux.iconPicker.prefs.load": () => null }, ["cmux.iconPicker.session"], {
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
    expect(await client.call("cmux.iconPicker.prefs.load", {})).toBeNull();
  } finally {
    stop?.();
    scope.webkit = savedWebkit;
    restore();
  }
});
