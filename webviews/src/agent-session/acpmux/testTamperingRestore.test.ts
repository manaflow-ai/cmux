import { expect, test } from "bun:test";
import { mergeToolItem } from "./direct";
import { restoreTestTampering, TEST_TAMPERING_RESTORE_METHOD } from "./testTamperingRestore";

test("status updates retain the durable finding event, a new report replaces its identity", () => {
  const tampering = {
    count: 1,
    files: [
      {
        path: "tests/a.rs",
        findings: [
          {
            kind: "introduced-skip",
            line: null,
            message: "skip",
            old: "#[test]",
            new: "#[test]\n#[ignore]",
          },
        ],
      },
    ],
  };
  const first = mergeToolItem(undefined, { kind: "edit", status: "in_progress", tampering }, "edit", "", 10, 42);
  const completed = mergeToolItem(first, { status: "completed" }, "edit", "", 11, 43);
  expect(completed.tool?.tampering).toEqual(tampering);
  expect(completed.tool?.tamperingEventSeq).toBe(42);
  const updated = mergeToolItem(completed, { tampering }, "edit", "", 12, 44);
  expect(updated.tool?.tamperingEventSeq).toBe(44);
});

test("restore sends only durable evidence coordinates and requires a confirmed result", async () => {
  const calls: unknown[] = [];
  await restoreTestTampering(
    async (...args) => {
      calls.push(args);
      return { restored: true };
    },
    "session-1",
    { eventSeq: 42, fileIndex: 1, findingIndex: 2 },
  );
  expect(calls).toEqual([
    [TEST_TAMPERING_RESTORE_METHOD, { sessionId: "session-1", eventSeq: 42, fileIndex: 1, findingIndex: 2 }, 15_000],
  ]);
  for (const reply of [undefined, {}, { restored: false }])
    await expect(
      restoreTestTampering(async () => reply, "session-1", {
        eventSeq: 42,
        fileIndex: 1,
        findingIndex: 2,
      }),
    ).rejects.toThrow();
});
