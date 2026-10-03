import { afterAll, beforeAll, expect, test } from "bun:test";
import { NativeTransport } from "./nativeTransport";
import { installDom } from "./testDom";
import type { SettingsEvent } from "./wire";

let restore: () => void;
beforeAll(() => {
  restore = installDom();
});
afterAll(() => restore());

test("requests post {op, params}; a rejected reply reads as unavailable; the bridge fans out events", async () => {
  const posted: unknown[] = [];
  const transport = new NativeTransport({
    postMessage(message) {
      posted.push(message);
      return message.op === "settings.reset_all"
        ? Promise.reject(new Error("relay down"))
        : Promise.resolve({ revision: 3, rows: [] });
    },
  });
  expect(await transport.request("settings.list", { section: "terminal" })).toEqual({ revision: 3, rows: [] });
  expect(posted).toEqual([{ op: "settings.list", params: { section: "terminal" } }]);
  expect(await transport.request("settings.reset_all", {})).toMatchObject({ error: { code: "unavailable" } });
  const events: SettingsEvent[] = [];
  transport.subscribe((event) => events.push(event));
  window.cmuxSettingsBridge!.dispatch({ type: "settings.changed", revision: 4, keys: ["a.b"] });
  window.cmuxSettingsBridge!.applyTheme({ isDark: true, text: "rgba(1, 1, 1, 1)" });
  expect(events).toEqual([{ type: "settings.changed", revision: 4, keys: ["a.b"] }]);
  expect(document.documentElement.style.getPropertyValue("--text")).toBe("rgba(1, 1, 1, 1)");
});
