import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { normalizePromptContentPart, promptContentParts } from "./promptContent";

const row = (inlineParts?: AcpmuxRow["inlineParts"]): Pick<AcpmuxRow, "inlineParts"> => ({ inlineParts });

test("keeps image, text, image, text in the recorded order", () => {
  const parts = promptContentParts(
    row([
      { kind: "image", id: "first", mimeType: "image/png", name: "first.png" },
      { kind: "text", text: "caption one" },
      { kind: "image", id: "second", mimeType: "image/jpeg", name: "second.jpg" },
      { kind: "text", text: "caption two" },
    ]),
  );

  expect(parts.map((part) => (part.kind === "text" ? `text:${part.text}` : `${part.kind}:${part.id}`))).toEqual([
    "image:first",
    "text:caption one",
    "image:second",
    "text:caption two",
  ]);
});

test("normalizes ACP type discriminators and leaves legacy rows to the fallback", () => {
  expect(normalizePromptContentPart({ type: "document", name: "brief.pdf", mimeType: "application/pdf" })).toEqual({
    kind: "document",
    name: "brief.pdf",
    mimeType: "application/pdf",
  });
  expect(promptContentParts(row(undefined))).toEqual([]);
  expect(promptContentParts(row([]))).toEqual([]);
});
