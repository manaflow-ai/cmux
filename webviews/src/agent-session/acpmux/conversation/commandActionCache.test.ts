// A live line asks for the same running command's action on every render: it is read once and kept
// (settled-page bench, chat_switch stream), and the kept reads stay bounded.
import { expect, test } from "bun:test";
import { commandAction, commandActionsKept } from "./commandActions";

test("the same command is parsed once: the second ask returns the kept action", () => {
  const command = "cat docs/notes/settled-page.md";
  const first = commandAction(command);
  expect(first?.key).toBe("command.read");
  expect(commandAction(command)).toBe(first);
});

test("a command the table does not list is kept as no action", () => {
  expect(commandAction("frobnicate --all")).toBeUndefined();
  expect(commandAction("frobnicate --all")).toBeUndefined();
});

test("the kept reads are bounded, the oldest out first", () => {
  const kept = commandAction("cat keep-me.md");
  for (let i = 0; i < 300; i += 1) {
    commandAction(`cat file-${i}.md`);
    // Asked again, the first one stays newest and is never dropped.
    expect(commandAction("cat keep-me.md")).toBe(kept);
  }
  expect(commandActionsKept()).toBeLessThanOrEqual(256);
  // One long out of the cache reads the same again.
  expect(commandAction("cat file-0.md")?.files).toEqual(["file-0.md"]);
});
