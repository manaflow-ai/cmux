// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import { contextAccess, contextSave, type ContextOverrideClient } from "./contextAccess";
import type { ContextOverride } from "./ContextScreen";

function recorder(): ContextOverrideClient & { calls: Array<[ContextOverride, string | undefined]> } {
  const calls: Array<[ContextOverride, string | undefined]> = [];
  return {
    calls,
    setContextOverride(change, sessionId) {
      calls.push([change, sessionId]);
      return Promise.resolve({ parts: [] });
    },
  };
}

const edit: ContextOverride = { scope: "project", text: "Read early." };

test("a chat on this Mac shows Context and saves through the client", async () => {
  const snapshot = { origin: "local" as const, sessionId: "s" };
  expect(contextAccess(snapshot)).toBe(true);
  const client = recorder();
  await contextSave(snapshot, client, "s")?.(edit);
  expect(client.calls).toEqual([[edit, "s"]]);
});

test("a remote owner's Cloud chat shows Context, and its save and reset reach the client", async () => {
  // The app's wire to the person's own Cloud machine: the daemon admits this owner carrier.
  const snapshot = { origin: "remote" as const, ownerCloud: true, sessionId: "s" };
  expect(contextAccess(snapshot)).toBe(true);
  const client = recorder();
  const save = contextSave(snapshot, client, "s");
  expect(save).toBeDefined();
  await save?.(edit);
  await save?.({ scope: "user", text: null });
  expect(client.calls).toEqual([
    [edit, "s"],
    [{ scope: "user", text: null }, "s"],
  ]);
});

test("a remote observer, teammate or link guest gets no Context and no save", () => {
  // None of these wires carries ownerCloud: an observation never does (AgentTabRemoteHost
  // passes it only to an attach), and a teammate or guest does not own the machine.
  for (const snapshot of [
    { origin: "remote" as const, sessionId: "s" },
    { origin: "remote" as const, ownerCloud: false, sessionId: "s" },
    { origin: "peer" as const, ownerCloud: true, sessionId: "s" },
    { origin: "unknown" as const, ownerCloud: true, sessionId: "s" },
  ]) {
    expect(contextAccess(snapshot)).toBe(false);
    const client = recorder();
    expect(contextSave(snapshot, client, "s")).toBeUndefined();
    expect(client.calls).toEqual([]);
  }
});

test("no chat yet: no Context and no save", () => {
  const owner = { origin: "remote" as const, ownerCloud: true };
  expect(contextAccess(owner)).toBe(false);
  expect(contextSave(owner, recorder(), undefined)).toBeUndefined();
  expect(contextSave({ origin: "local" }, recorder(), "s")).toBeUndefined();
});
