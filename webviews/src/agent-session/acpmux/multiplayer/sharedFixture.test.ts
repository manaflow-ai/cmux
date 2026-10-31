// `debug.agent_pane seed_rows` with `fixture: "shared"`: the real app's capture of a shared chat
// draws teammates' prompts and the live faces for the chat on screen.
import { afterEach, expect, test } from "bun:test";
import { createAcpmuxDebug } from "../debug";
import type { AcpmuxRow } from "../model";
import { acpmuxPerf } from "../perf";
import { shownPresence } from "./LivePresence";
import { PresenceClient } from "./presenceClient";

afterEach(() => shownPresence.set(undefined, undefined));

test("the shared fixture seeds teammates' rows and shows who is here, for the chat on screen", async () => {
  let rows: AcpmuxRow[] = [];
  const debug = createAcpmuxDebug({
    // The pane commits the rows it is given; the seed waits for that commit.
    replaceRows: (next) => {
      rows = next;
      queueMicrotask(() => acpmuxPerf.commit(1, 0, [], performance.now()));
    },
    rowCount: () => rows.length,
    sessionId: () => "chat-a",
  });
  const seeded = await debug.seedRows(0, "shared");
  expect(seeded.rows).toBe(rows.length);
  expect(rows.filter((row) => row.author).map((row) => row.author!.name)).toEqual(["Ana Ruiz", "Sam Okafor"]);
  expect(rows.find((row) => row.answeredBy)?.answeredBy?.name).toBe("Sam Okafor");
  expect(shownPresence.get()?.sessionId).toBe("chat-a");
  expect(shownPresence.get()?.presence?.viewing.map((p) => p.name)).toEqual(["Ana Ruiz", "Sam Okafor", "Mei Lin"]);
  expect(shownPresence.get()?.presence?.typing.map((p) => p.name)).toEqual(["Ana Ruiz"]);
});

test("seeding another fixture after the shared one restores the live presence from before", async () => {
  let rows: AcpmuxRow[] = [];
  const debug = createAcpmuxDebug({
    replaceRows: (next) => {
      rows = next;
      queueMicrotask(() => acpmuxPerf.commit(1, 0, [], performance.now()));
    },
    rowCount: () => rows.length,
    sessionId: () => "chat-a",
  });
  const live = { viewing: [{ id: "tailnet:real@example.com", name: "Real Person" }], typing: [] };
  shownPresence.set("chat-a", live);
  await debug.seedRows(0, "shared");
  await debug.seedRows(0, "shared");
  expect(shownPresence.get()?.presence?.viewing.map((p) => p.name)).toEqual(["Ana Ruiz", "Sam Okafor", "Mei Lin"]);
  await debug.seedRows(3, "short");
  expect(shownPresence.get()).toEqual({ sessionId: "chat-a", presence: live });
  // With nothing live before, leaving the fixture draws no faces.
  shownPresence.set(undefined, undefined);
  await debug.seedRows(0, "shared");
  await debug.seedRows(3, "short");
  expect(shownPresence.get()).toBeUndefined();
  // A presence the chat's own acpmux set while the fixture showed is kept.
  await debug.seedRows(0, "shared");
  const newer = { viewing: [], typing: [] };
  shownPresence.set("chat-a", newer);
  await debug.seedRows(3, "short");
  expect(shownPresence.get()?.presence).toBe(newer);
});

test("a shared seed after live presence or a switch displaced the fixture restores the newer presence", async () => {
  let rows: AcpmuxRow[] = [];
  let session = "chat-a";
  const debug = createAcpmuxDebug({
    replaceRows: (next) => {
      rows = next;
      queueMicrotask(() => acpmuxPerf.commit(1, 0, [], performance.now()));
    },
    rowCount: () => rows.length,
    sessionId: () => session,
  });
  const inA = { viewing: [{ id: "tailnet:a@example.com", name: "In A" }], typing: [] };
  const inB = { viewing: [{ id: "tailnet:b@example.com", name: "In B" }], typing: [] };
  shownPresence.set("chat-a", inA);
  await debug.seedRows(0, "shared");
  // A switch to chat B, whose acpmux sends its presence, then the fixture again over B.
  session = "chat-b";
  shownPresence.set("chat-b", inB);
  await debug.seedRows(0, "shared");
  expect(shownPresence.get()?.sessionId).toBe("chat-b");
  await debug.seedRows(3, "short");
  expect(shownPresence.get()).toEqual({ sessionId: "chat-b", presence: inB });
  // A live update in one chat displaces the fixture; seeding again keeps the update as baseline.
  await debug.seedRows(0, "shared");
  const update = { viewing: [], typing: [] };
  shownPresence.set("chat-b", update);
  await debug.seedRows(0, "shared");
  await debug.seedRows(3, "short");
  expect(shownPresence.get()?.presence).toBe(update);
  // A switch with no presence yet: the fixture's faces over chat B are not chat C's baseline.
  await debug.seedRows(0, "shared");
  session = "chat-c";
  await debug.seedRows(0, "shared");
  await debug.seedRows(3, "short");
  expect(shownPresence.get()).toBeUndefined();
});

test("a chat switch clears the fixture's faces even when no chat has anyone else", async () => {
  // Wired as the direct client wires it (direct.ts `presence`): every attach and detach tells.
  const client: PresenceClient = new PresenceClient(
    () => undefined,
    () => shownPresence.set(client.chat, client.presence),
  );
  let rows: AcpmuxRow[] = [];
  const debug = createAcpmuxDebug({
    replaceRows: (next) => {
      rows = next;
      queueMicrotask(() => acpmuxPerf.commit(1, 0, [], performance.now()));
    },
    rowCount: () => rows.length,
    sessionId: () => client.chat,
  });
  client.attached("chat-a", {});
  await debug.seedRows(0, "shared");
  expect(shownPresence.get()?.presence?.viewing).toHaveLength(3);
  client.detached();
  expect(shownPresence.get()).toBeUndefined();
  client.attached("chat-b", {});
  client.detached();
  client.attached("chat-a", {});
  expect(shownPresence.get()).toEqual({ sessionId: "chat-a", presence: undefined });
  // An acpmux that sends presence, with nobody else here, clears it the same way.
  await debug.seedRows(0, "shared");
  client.detached();
  client.attached("chat-a", { presence: { viewing: [], typing: [] } });
  expect(shownPresence.get()?.presence).toBeUndefined();
});
