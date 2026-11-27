// Leo, 2026-11-22: "FUCKING RECONNECTING JUST LET ME SEND WHY WOULD IT FUCKING BLOCK SENDS IN THE
// FIRST PLACE STUPID STUPID FUCKING DESIGN". Prompts sent while the pane has no link are taken at
// once, drawn as pending rows, kept on disk, and go once each, in order, when the link is back.
import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { OFFLINE_NOT_CONNECTED, OfflineSends, lostToLink, offlineRecord, withOfflineSends } from "./offlineSends";
import type { UnsentPromptRecord, UnsentPromptStore } from "./unsentPrompts";

function memoryStore() {
  const chats = new Map<string, Map<string, UnsentPromptRecord>>();
  const store: UnsentPromptStore = {
    read: async (chat) => [...(chats.get(chat)?.values() ?? [])],
    put: async (chat, record) => {
      const kept = chats.get(chat) ?? new Map();
      kept.set(record.promptId, record);
      chats.set(chat, kept);
    },
    remove: async (chat, id) => {
      chats.get(chat)?.delete(id);
    },
  };
  return { store, ids: (chat: string) => [...(chats.get(chat)?.keys() ?? [])] };
}

const snapshot = (rows: AcpmuxSnapshot["rows"] = []): AcpmuxSnapshot =>
  ({ sessionId: "chat", rows }) as unknown as AcpmuxSnapshot;

test("three prompts sent while the link is down show at once, are kept on disk, and go once each in order", async () => {
  const { store, ids } = memoryStore();
  const sends = new OfflineSends(store);
  for (const text of ["one", "two", "three"]) sends.add("chat", text, [], `p-${text}`);
  // Shown at once as pending user rows, in the order sent.
  const drawn = withOfflineSends(snapshot(), sends.in("chat")).rows;
  expect(drawn.map((row) => [row.id, row.kind, row.text, row.pending])).toEqual([
    ["local-p-one", "user", "one", true],
    ["local-p-two", "user", "two", true],
    ["local-p-three", "user", "three", true],
  ]);
  await Promise.resolve();
  expect(ids("chat")).toEqual(["p-one", "p-two", "p-three"]);
  // Nothing goes while the link is down.
  const sent: string[] = [];
  let up = false;
  await sends.flush(
    "chat",
    () => up,
    async (item) => void sent.push(item.id),
    () => "wait",
  );
  expect(sent).toEqual([]);
  // The link returns: each goes once, in order, under its own prompt id.
  up = true;
  await sends.flush(
    "chat",
    () => up,
    async (item) => void sent.push(item.id),
    () => "wait",
  );
  expect(sent).toEqual(["p-one", "p-two", "p-three"]);
  expect(sends.in("chat")).toEqual([]);
  // A second flush sends nothing again.
  await sends.flush(
    "chat",
    () => up,
    async (item) => void sent.push(item.id),
    () => "wait",
  );
  expect(sent).toEqual(["p-one", "p-two", "p-three"]);
});

test("a send that loses the link keeps its place and its prompt id, and goes before the later ones", async () => {
  const { store, ids } = memoryStore();
  const sends = new OfflineSends(store);
  sends.add("chat", "one", [], "a");
  sends.add("chat", "two", [], "b");
  const attempts: string[] = [];
  let drop = true;
  const send = async (item: { id: string }) => {
    attempts.push(item.id);
    if (drop) {
      drop = false;
      throw new Error(OFFLINE_NOT_CONNECTED);
    }
  };
  await sends.flush(
    "chat",
    () => true,
    send,
    (_item, error) => (lostToLink(error) ? "wait" : "dropped"),
  );
  expect(attempts).toEqual(["a"]);
  expect(sends.in("chat").map((item) => item.id)).toEqual(["a", "b"]);
  await Promise.resolve();
  expect(ids("chat")).toEqual(["a", "b"]);
  // A new link ends the back-off; the same id goes again (acpmux runs an id at most once).
  sends.linkChanged();
  await sends.flush(
    "chat",
    () => true,
    send,
    () => "wait",
  );
  expect(attempts).toEqual(["a", "a", "b"]);
  expect(sends.in("chat")).toEqual([]);
});

test("a refused prompt leaves the queue for where the caller put it; the next one still goes", async () => {
  const sends = new OfflineSends();
  sends.add("chat", "refused", [], "r");
  sends.add("chat", "fine", [], "f");
  const sent: string[] = [];
  const failedWith: string[] = [];
  await sends.flush(
    "chat",
    () => true,
    async (item) => {
      if (item.id === "r") throw new Error("refused");
      sent.push(item.id);
    },
    (item) => {
      failedWith.push(item.id);
      return "dropped";
    },
  );
  expect(failedWith).toEqual(["r"]);
  expect(sent).toEqual(["f"]);
  expect(sends.in("chat")).toEqual([]);
});

test("a reload adopts the queued prompts on disk once, oldest first, and never the Not sent ones", () => {
  const sends = new OfflineSends();
  const later = offlineRecord({ id: "later", chat: "chat", text: "later", attachments: [], at: 20 });
  const earlier = offlineRecord({ id: "earlier", chat: "chat", text: "earlier", attachments: [], at: 10 });
  const refused: UnsentPromptRecord = { promptId: "refused", input: "x", attachments: [], at: 5, error: "Not sent" };
  sends.adopt("chat", [later, earlier, refused]);
  sends.adopt("chat", [later, earlier]);
  expect(sends.in("chat").map((item) => item.id)).toEqual(["earlier", "later"]);
});

test("a queued prompt the chat's client already draws is one row, not two", () => {
  const sends = new OfflineSends();
  sends.add("chat", "one", [], "p1");
  const clientRow = { id: "local-p1", kind: "user", text: "one", promptId: "p1" } as AcpmuxSnapshot["rows"][number];
  expect(withOfflineSends(snapshot([clientRow]), sends.in("chat")).rows).toHaveLength(1);
  // Another chat's prompts are not drawn here.
  expect(sends.in("other")).toEqual([]);
});
