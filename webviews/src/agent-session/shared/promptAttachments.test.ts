import { expect, test } from "bun:test";
import { promptTextWithAttachments } from "./promptAttachments";
import type { AgentSessionAttachment } from "./types";

test("promptTextWithAttachments encodes file paths before building markdown links", () => {
  const attachments: AgentSessionAttachment[] = [
    {
      id: "attachment-1",
      kind: "file",
      label: "my file (draft).txt",
      path: "/Users/me/Library/Application Support/my file (draft).txt",
    },
  ];

  expect(promptTextWithAttachments("summarize", attachments)).toBe(
    "[my file (draft).txt](/Users/me/Library/Application%20Support/my%20file%20\\(draft\\).txt)\n\nsummarize",
  );
});
