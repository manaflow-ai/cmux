import { expect, test } from "bun:test";
import { FakeTransport, fakeManagedKey } from "./fakeTransport";
import { schema } from "./schema";
import type { SettingsEvent } from "./wire";

test("the fake validates every row like the schema's accept/refuse fixtures", async () => {
  const fake = new FakeTransport({ managed: {} });
  const failures: string[] = [];
  for (const row of schema.rows) {
    for (const value of row.accepts) {
      const reply = (await fake.request("settings.set", { key: row.key, value })) as { error?: unknown };
      if (reply.error) failures.push(`${row.key} refused ${JSON.stringify(value)}`);
    }
    for (const value of row.refuses) {
      const reply = (await fake.request("settings.set", { key: row.key, value })) as { error?: { code: string } };
      if (reply.error?.code !== "invalid_params") failures.push(`${row.key} accepted ${JSON.stringify(value)}`);
    }
  }
  expect(failures).toEqual([]);
});

test("writes bump the revision and emit settings.changed; managed keys refuse with the reason", async () => {
  const fake = new FakeTransport();
  const events: SettingsEvent[] = [];
  fake.subscribe((event) => events.push(event));
  expect(await fake.request("settings.set", { key: "terminal.fontSize", value: 14 })).toEqual({ revision: 2 });
  await Promise.resolve();
  expect(events).toEqual([{ type: "settings.changed", revision: 2, keys: ["terminal.fontSize"] }]);
  const list = (await fake.request("settings.list", { section: "terminal" })) as {
    rows: Array<{ key: string; value: unknown; customized: boolean }>;
  };
  expect(list.rows.find((row) => row.key === "terminal.fontSize")).toMatchObject({ value: 14, customized: true });
  expect(await fake.request("settings.set", { key: fakeManagedKey, value: true })).toEqual({
    error: {
      code: "managed",
      message: "Set by your organization's profile",
      details: { source: "profile", reason: "Set by your organization's profile" },
    },
  });
  const snapshot = (await fake.request("settings.snapshot", {})) as unknown as {
    effective: { terminal: { fontSize: number } };
  };
  expect(snapshot.effective.terminal.fontSize).toBe(14);
  fake.setConnected(false);
  expect(await fake.request("settings.list", {})).toMatchObject({ error: { code: "unavailable" } });
});

test("reset_all keeps the rows marked kept_on_reset_all", async () => {
  const fake = new FakeTransport({
    values: { "terminal.fontFamily": "Menlo", "terminal.fontSize": 15, "focusRing.width": 3 },
  });
  await fake.request("settings.reset_all", {});
  const list = (await fake.request("settings.list", {})) as { rows: Array<{ key: string; customized: boolean }> };
  const customized = list.rows.filter((row) => row.customized).map((row) => row.key);
  expect(customized).toEqual(["terminal.fontFamily", "terminal.fontSize"]);
});
