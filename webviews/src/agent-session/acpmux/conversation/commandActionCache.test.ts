// A live line asks for the same running command's action on every render: it is read once and kept
// (settled-page bench, chat_switch stream), and the kept reads stay bounded.
import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import { commandAction, commandActionsKept, commandSaid, runningSaidKept } from "./commandActions";

const t = translatorFor("en");
const runningShell = (command: string) =>
  ({ kind: "execute", command, status: "in_progress" }) as Parameters<typeof commandSaid>[1];

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

test("a running command's live line is read once per command, in each language", () => {
  const before = runningSaidKept();
  const first = commandSaid(t, runningShell("sleep 30"));
  expect(first).toBe("Waiting 30s");
  const kept = runningSaidKept();
  expect(kept).toBeGreaterThanOrEqual(before);
  for (let i = 0; i < 20; i += 1) expect(commandSaid(t, runningShell("sleep 30"))).toBe(first);
  expect(runningSaidKept()).toBe(kept);
  // Finished, the same command reads past tense: the kept running line is not used.
  expect(commandSaid(t, { ...runningShell("sleep 30"), status: "completed" })).toBe("Waited 30s");
  // Another translator starts over: what is kept is that language's line only.
  const other = translatorFor("ja");
  expect(typeof commandSaid(other, runningShell("sleep 30"))).toBe("string");
  expect(runningSaidKept()).toBe(1);
});
