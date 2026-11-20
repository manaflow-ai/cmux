// l10n-allow-file: synthetic extension command names and texts.
import { describe, expect, test } from "bun:test";
import { Schema } from "@milkdown/kit/prose/model";
import { history, undo } from "@milkdown/kit/prose/history";
import { EditorState, TextSelection } from "@milkdown/kit/prose/state";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { mergedCommands } from "../cmuxCommands";
import { applyCommand, returnPicks, slashMatches, slashNames, slashTrigger } from "../slashCommands";
import { ExtensionCommands, extensionCommandsFrom, withExtensionCommands } from "./extensionCommands";
import { commandEdit, slashTokensPlugin } from "./slashTokens";

const schema = new Schema({
  nodes: {
    doc: { content: "block+" },
    paragraph: { group: "block", content: "inline*" },
    text: { group: "inline" },
    hardbreak: { group: "inline", inline: true },
  },
});

/// A one-paragraph editor with the caret at `|`.
function editor(line: string): EditorState {
  const at = line.indexOf("|");
  const text = line.replace("|", "");
  const made = schema.node("doc", null, [schema.node("paragraph", null, text ? [schema.text(text)] : [])]);
  return EditorState.create({
    doc: made,
    selection: TextSelection.create(made, 1 + at),
    plugins: [history(), slashTokensPlugin(() => slashNames([]))],
  });
}

const STANDUP = {
  app: "local/standup",
  extension: "Standup",
  name: "standup",
  description: "Ask for today's standup",
  insert: "Write my standup notes.",
};

/// Reads the daemon's list the way the page does, through the page host client.
async function listed(client: MockAppPanelsClient): Promise<ExtensionCommands> {
  const owner = new ExtensionCommands(client);
  owner.start();
  await owner.refresh();
  return owner;
}

describe("extension slash commands (cmux.composer.command/1)", () => {
  test("a sample command from an extension is listed in the / menu and its pick inserts its text", async () => {
    const client = new MockAppPanelsClient();
    client.composerCommands = [STANDUP];
    const owner = await listed(client);
    const commands = withExtensionCommands(mergedCommands([]), owner.getSnapshot());

    const rows = slashMatches(commands, slashTrigger("/stand", 0)!);
    expect([rows[0]!.command.name, rows[0]!.command.source, rows[0]!.command.extension]).toEqual([
      "standup",
      "extension",
      "Standup",
    ]);

    // In the editor: the typed `/stand` becomes the command's text, one undo step, the caret after it.
    const start = editor("/stand|");
    const picked = start.apply(commandEdit(start, "standup", rows[0]!.command.insert)!);
    expect(picked.doc.textContent).toBe("Write my standup notes.");
    expect(picked.selection.from).toBe(1 + "Write my standup notes.".length);
    let undone = picked;
    undo(picked, (tr) => (undone = picked.apply(tr)));
    expect(undone.doc.textContent).toBe("/stand");

    // With no editor (the plain field): the same text.
    expect(applyCommand("/stand", 6, rows[0]!.command)).toEqual({
      text: "Write my standup notes.",
      caret: "Write my standup notes.".length,
    });
    // Return on the whole name writes the text; it never sends `/standup` to the agent.
    expect(returnPicks(rows[0], "standup", false)).toBe(true);
    owner.stop();
  });

  test("mid-prompt the command writes its text there, the words around it kept", () => {
    const commands = extensionCommandsFrom({ commands: [STANDUP] });
    expect(slashMatches(commands, slashTrigger("then /st", undefined)!).map((m) => m.command.name)).toEqual([
      "standup",
    ]);
    const start = editor("then /st| please");
    const next = start.apply(commandEdit(start, "standup", commands[0]!.insert)!);
    expect(next.doc.textContent).toBe("then Write my standup notes. please");
  });

  test("a multi-line text is written with line breaks", () => {
    const start = editor("/stand|");
    const next = start.apply(commandEdit(start, "standup", "Yesterday:\nToday:")!);
    expect(next.doc.firstChild!.childCount).toBe(3);
    expect(next.doc.firstChild!.child(1).type.name).toBe("hardbreak");
  });

  test("a save of the extension's command updates the list with no restart", async () => {
    const client = new MockAppPanelsClient();
    client.composerCommands = [STANDUP];
    const owner = await listed(client);
    let heard = 0;
    owner.subscribe(() => heard++);
    expect(owner.getSnapshot().map((command) => command.insert)).toEqual(["Write my standup notes."]);

    // The daemon's local reload says `apps-changed`; the host forwards it as `cmux.apps.panels.changed`.
    client.setComposerCommands([
      { ...STANDUP, insert: "New standup text." },
      { ...STANDUP, name: "retro", insert: "Retro." },
    ]);
    await owner.refresh();
    expect(owner.getSnapshot().map((command) => [command.name, command.insert])).toEqual([
      ["standup", "New standup text."],
      ["retro", "Retro."],
    ]);
    expect(heard).toBeGreaterThan(0);
    owner.stop();
  });

  test("a name cmux or the agent has stays theirs, and a bad entry is dropped", () => {
    const extension = extensionCommandsFrom({
      commands: [
        { name: "model", insert: "not the picker" },
        { name: "", insert: "x" },
        { name: "empty", insert: "" },
        STANDUP,
      ],
    });
    const merged = withExtensionCommands(mergedCommands([{ name: "compact", description: "" }]), extension);
    expect(merged.filter((command) => command.name === "model").map((command) => command.source)).toEqual(["cmux"]);
    expect(merged.filter((command) => command.source === "extension").map((command) => command.name)).toEqual([
      "standup",
    ]);
  });

  test("an older host with no composer op lists none, with no error", async () => {
    const client = new MockAppPanelsClient();
    client.call = () => Promise.reject(new Error("cmux.protocol.unknown_op"));
    const owner = await listed(client);
    expect(owner.getSnapshot()).toEqual([]);
    owner.stop();
  });

  test("an extension's command is never drawn blue in the prompt (its text replaces it)", () => {
    const names = slashNames(extensionCommandsFrom({ commands: [STANDUP] }));
    expect(names.leading.has("standup")).toBe(false);
  });
});
