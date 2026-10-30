import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { archiveClosesTab } from "./archiveClose";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key] === undefined) delete scope[key];
    else scope[key] = saved[key];
  dom.window.close();
});

async function connected() {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  return AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
}

test("archiving A while the person switches to B keeps B's tab", async () => {
  const client = await connected();
  try {
    const replacement = await client.startSession("claude");
    const archived = client.selectedSession!;
    expect(replacement).toBeDefined();
    // startSession selects the new chat; go back to A, the chat the archive acts on.
    const original = (await client.select(archived)) ?? archived;
    expect(client.selectedSession).toBe(original);
    const selection = client.selectionToken;
    const pending = client.archive(true);
    // The person selects B before A's archive answers.
    await client.select(replacement!);
    await pending;
    expect(client.selectedSession).toBe(replacement);
    expect(archiveClosesTab(client, original, selection)).toBe(false);
  } finally {
    client.close();
  }
});

test("archiving the shown chat closes its tab", async () => {
  const client = await connected();
  try {
    const archived = client.selectedSession!;
    const selection = client.selectionToken;
    await client.archive(true);
    expect(archiveClosesTab(client, archived, selection)).toBe(true);
  } finally {
    client.close();
  }
});

test("the client's own fallback away from the archived chat is the archive's completion", () => {
  const fake = (selected: string | undefined, fellBack: string | undefined) => ({
    selectionToken: 2,
    selectedSession: selected,
    fellBackFrom: (id: string | undefined) => id !== undefined && id === fellBack,
  });
  // The list dropped A and the client fell back to the most recent chat, or to none.
  expect(archiveClosesTab(fake("B", "A"), "A", 1)).toBe(true);
  expect(archiveClosesTab(fake(undefined, "A"), "A", 1)).toBe(true);
  // The person selected B (or the selection cleared) meanwhile: not this archive's to close.
  expect(archiveClosesTab(fake("B", undefined), "A", 1)).toBe(false);
  expect(archiveClosesTab(fake(undefined, undefined), "A", 1)).toBe(false);
  expect(archiveClosesTab(fake("B", "A"), undefined, 1)).toBe(false);
});
