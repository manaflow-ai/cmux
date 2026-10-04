import { expect, test } from "bun:test";
import { createMockClient, mockManagedKey } from "./mockProvider";
import type { ListRow, MutationResult, SettingsStreams, SnapshotResult } from "./ops";
import { schema } from "./schema";

const key = () => crypto.randomUUID();

test("the mock validates every row like the schema's accept/refuse samples", async () => {
  const { client, close } = createMockClient({ managed: {} });
  const failures: string[] = [];
  for (const row of schema.rows) {
    for (const value of row.accepts) {
      await client
        .call("cmux.settings.set", { key: row.key, value, idempotency_key: key() })
        .catch(() => failures.push(`${row.key} refused ${JSON.stringify(value)}`));
    }
    for (const value of row.refuses) {
      const code = await client.call("cmux.settings.set", { key: row.key, value, idempotency_key: key() }).then(
        () => "accepted",
        (error: { code: string }) => error.code,
      );
      if (code !== "cmux.settings.invalid") failures.push(`${row.key} accepted ${JSON.stringify(value)}`);
    }
  }
  close();
  expect(failures).toEqual([]);
});

test("writes go over the protocol envelope: revision, changed event, managed refusal, keys required", async () => {
  const { client, provider, close } = createMockClient();
  const events: Array<SettingsStreams["cmux.settings.changed"]> = [];
  await client.subscribe<SettingsStreams["cmux.settings.changed"]>("cmux.settings.changed", (event) => {
    events.push(event);
  });
  const result = await client.call<MutationResult>("cmux.settings.set", {
    key: "terminal.fontSize",
    value: 14,
    idempotency_key: "k1",
  });
  expect(result).toEqual({ value: { keys: ["terminal.fontSize"] }, revision: "2", replayed: false });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(events).toEqual([{ revision: 2, keys: ["terminal.fontSize"], origin: "user" }]);
  const rows = await client.call<ListRow[]>("cmux.settings.list", { section: "terminal" });
  expect(rows.find((row) => row.key === "terminal.fontSize")).toMatchObject({ value: 14, customized: true });
  const managed = await client
    .call("cmux.settings.set", { key: mockManagedKey, value: true, idempotency_key: key() })
    .catch((error: { code: string; message: string; details: unknown }) => error);
  expect(managed).toMatchObject({
    code: "cmux.settings.managed",
    message: "Set by your organization's profile",
    details: { key: mockManagedKey, source: "profile" },
  });
  const missingKey = await client
    .call("cmux.settings.set", { key: "terminal.fontSize", value: 15 })
    .catch((error: { code: string }) => error.code);
  expect(missingKey).toBe("cmux.protocol.invalid_params");
  const reused = await client
    .call("cmux.settings.set", { key: "terminal.fontSize", value: 16, idempotency_key: "k1" })
    .catch((error: { code: string }) => error.code);
  expect(reused).toBe("cmux.idempotency.conflict");
  const snapshot = await client.call<SnapshotResult>("cmux.settings.snapshot", {});
  expect((snapshot.effective.terminal as { fontSize: number }).fontSize).toBe(14);
  expect(snapshot.domains?.themes).toContain("Dracula");
  provider.setConnected(false);
  const offline = await client.call("cmux.settings.list", {}).catch((error: { code: string }) => error.code);
  expect(offline).toBe("cmux.protocol.closed");
  close();
});

test("reset_all keeps the rows marked kept_on_reset_all", async () => {
  const { client, close } = createMockClient({
    values: { "terminal.fontFamily": "Menlo", "terminal.fontSize": 15, "focusRing.width": 3 },
  });
  await client.call("cmux.settings.reset_all", { idempotency_key: key() });
  const rows = await client.call<ListRow[]>("cmux.settings.list", {});
  expect(rows.filter((row) => row.customized).map((row) => row.key)).toEqual([
    "terminal.fontFamily",
    "terminal.fontSize",
  ]);
  close();
});
