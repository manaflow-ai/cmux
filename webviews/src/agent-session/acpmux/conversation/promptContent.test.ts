import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { hasPromptAttachments, normalizePromptContentPart, promptContentParts } from "./promptContent";

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

test("keeps durable image identity when the daemon could not persist a middle image", () => {
  const parts = promptContentParts(
    row([
      { kind: "image", id: "sha-first", mimeType: "image/png" },
      { kind: "text", text: "caption" },
      { kind: "image", id: "sha-middle", mimeType: "image/png", persisted: false },
      { kind: "image", id: "sha-last", mimeType: "image/png" },
    ]),
  );
  expect(parts.filter((part) => part.kind === "image").map((part) => part.id)).toEqual([
    "sha-first",
    "sha-middle",
    "sha-last",
  ]);
  expect(parts[2]).toMatchObject({ kind: "image", id: "sha-middle", persisted: false });
});

test("rehydrates text-file and pasted chips with their durable block text", () => {
  const parts = promptContentParts(
    row([
      { kind: "file", name: "notes.txt", mimeType: "text/plain", text: "notes.txt\n```\nbody\n```" },
      { kind: "pasted", name: "Pasted text", text: "a large paste" },
    ]),
  );
  expect(parts).toEqual([
    expect.objectContaining({ kind: "file", name: "notes.txt", text: "notes.txt\n```\nbody\n```" }),
    expect.objectContaining({ kind: "pasted", name: "Pasted text", text: "a large paste" }),
  ]);
});


test("a trailing attachment uses the ordered layout, while text alone keeps its plain bubble", () => {
  expect(hasPromptAttachments([{ kind: "text", text: "Look at this" }, { kind: "image" }])).toBe(true);
  expect(hasPromptAttachments([{ kind: "file" }])).toBe(true);
  expect(hasPromptAttachments([{ kind: "text", text: "Long text" }])).toBe(false);
  expect(hasPromptAttachments(undefined)).toBe(false);
});
