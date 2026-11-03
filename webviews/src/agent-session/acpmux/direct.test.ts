import { expect, test } from "bun:test";
import { mergeToolItem } from "./direct";
import { isDraftCall } from "./conversation/toolGroups";

test("an empty rawInput update keeps a draft tool call's command", () => {
  const draft = mergeToolItem(
    undefined,
    { title: "Bash", kind: "execute", status: "in_progress", rawInput: { command: "echo hello" } },
    "call-1",
    "",
    1,
  );
  const updated = mergeToolItem(draft, { status: "in_progress", rawInput: {} }, "call-1", "", 2);

  expect(updated.tool?.inputSummary).toBe(JSON.stringify({ command: "echo hello" }));
  expect(updated.tool?.command).toBe("echo hello");
  expect(isDraftCall(updated.tool!)).toBe(false);
});
