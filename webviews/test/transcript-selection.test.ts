import { expect, test } from "bun:test";

const { transcriptSelectionAttachment } = await import("../src/agent-session/acpmux/transcriptSelection");

test("each attached transcript selection gets a distinct named context id", () => {
  const first = transcriptSelectionAttachment("one selected span");
  const second = transcriptSelectionAttachment("one selected span");
  expect(first).toMatchObject({
    kind: "text",
    name: "Selection",
    mimeType: "text/plain",
    text: "one selected span",
  });
  expect(second).toMatchObject({ text: "one selected span" });
  expect(first?.id).not.toBe(second?.id);
  expect(transcriptSelectionAttachment("  ")).toBeUndefined();
});
