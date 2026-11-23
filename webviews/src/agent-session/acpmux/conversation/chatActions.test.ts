// l10n-allow-file: synthetic extension action titles.
// Message actions (`cmux.chat.action/1`): the daemon lists the installed extensions' rows for a
// prompt and a reply; the page adds them to the message's menu report, and with none the report
// (so the native menu) is exactly what it was.
import { expect, test } from "bun:test";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { ComposerContributions } from "../composer/extensionCommands";
import type { AcpmuxSnapshot } from "../model";
import { chatActionRowsFrom, withChatActions, type ChatActionRow } from "./chatActions";
import { chatActionMessage, messageMenuTarget } from "./messageMenu";

const rows = [
  { id: "u1", kind: "user", text: "fix the build", at: 1 },
  { id: "a1", kind: "assistant", text: "Done: **fixed**.", at: 2 },
  { id: "summary-t1", kind: "turnSummary", seq: 7, at: 3 },
];
const snapshot = { sessionId: "s1", canFork: false, connection: "connected", rows } as unknown as AcpmuxSnapshot;

const SAVE = { app: "local/notes", extension: "Notes", id: "save", title: "Save to Notes", symbol: "note.text" };
const TRANSLATE = { app: "local/notes", extension: "Notes", id: "translate", title: "Translate", roles: ["assistant"] };

/// Lists the role's actions the way the page does, through the page host client.
async function listed(client: MockAppPanelsClient, role: "user" | "assistant"): Promise<ChatActionRow[]> {
  const owner = new ComposerContributions(client, "cmux.apps.panels.chatActions", { role });
  owner.start();
  await owner.refresh();
  const out = chatActionRowsFrom(owner.getSnapshot());
  owner.stop();
  return out;
}

test("with no extension installed the menu report is unchanged", async () => {
  const client = new MockAppPanelsClient();
  const user = await listed(client, "user");
  const assistant = await listed(client, "assistant");
  for (const rowId of ["u1", "a1"]) {
    const target = messageMenuTarget(snapshot, rowId);
    const reported = withChatActions(target, chatActionMessage(snapshot, rowId), (role) =>
      role === "user" ? user : assistant,
    );
    expect(reported).toBe(target);
    expect(reported && "chatActions" in reported).toBe(false);
  }
});

test("an installed extension's actions join the menu report of the messages of their role", async () => {
  const client = new MockAppPanelsClient();
  client.chatActions = [SAVE, TRANSLATE];
  const user = await listed(client, "user");
  const assistant = await listed(client, "assistant");
  expect(user.map((row) => row.id)).toEqual(["save"]);
  expect(assistant.map((row) => row.id)).toEqual(["save", "translate"]);
  const read = (role: "user" | "assistant") => (role === "user" ? user : assistant);

  const reply = withChatActions(messageMenuTarget(snapshot, "a1"), chatActionMessage(snapshot, "a1"), read);
  expect(reply?.chatActions).toEqual({
    message: { id: "a1", role: "assistant", text: "Done: **fixed**.", session: "s1" },
    rows: [
      { app: "local/notes", id: "save", title: "Save to Notes", symbol: "note.text" },
      { app: "local/notes", id: "translate", title: "Translate" },
    ],
  });
  const prompt = withChatActions(messageMenuTarget(snapshot, "u1"), chatActionMessage(snapshot, "u1"), read);
  expect(prompt?.chatActions?.message).toEqual({ id: "u1", role: "user", text: "fix the build", session: "s1" });
  expect(prompt?.chatActions?.rows.map((row) => row.id)).toEqual(["save"]);
});

test("a save of the extension's manifest changes the next menu", async () => {
  const client = new MockAppPanelsClient();
  const owner = new ComposerContributions(client, "cmux.apps.panels.chatActions", { role: "user" });
  const stop = owner.subscribe(() => undefined);
  await owner.refresh();
  expect(chatActionRowsFrom(owner.getSnapshot())).toEqual([]);
  client.setChatActions([SAVE]);
  await owner.refresh();
  expect(chatActionRowsFrom(owner.getSnapshot()).map((row) => row.title)).toEqual(["Save to Notes"]);
  stop();
});

test("a row without an app, an id or a title is dropped, and a subagent's message gets none", () => {
  expect(chatActionRowsFrom({ actions: [{ app: "a", id: "x" }, { id: "y", title: "Y" }, null, SAVE] })).toEqual([
    { app: "local/notes", id: "save", title: "Save to Notes", symbol: "note.text" },
  ]);
  expect(chatActionRowsFrom(null)).toEqual([]);
  expect(chatActionMessage(snapshot, "a1", rows as unknown as AcpmuxSnapshot["rows"])).toBeUndefined();
  expect(chatActionMessage(snapshot, "summary-t1")).toBeUndefined();
});
