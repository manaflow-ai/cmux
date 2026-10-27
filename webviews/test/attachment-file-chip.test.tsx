// l10n-allow-file: synthetic attachment names and prompts for a behavioral regression.
import { expect, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { AttachmentStrip } from "../src/agent-session/acpmux/composer/attachmentIntake";
import { UserBubble } from "../src/agent-session/acpmux/conversation/UserBubble";
import { attachmentPath } from "../src/agent-session/acpmux/FileAttachment";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";

const file: ComposerAttachment = {
  id: "pem",
  kind: "link",
  name: "manaflow-cmux-production-key.pem",
  mimeType: "application/x-pem-file",
  size: 2048,
  saved: true,
  path: "/Users/sample/Keys/manaflow-cmux-production-key.pem",
};

test("a staged file shows its type, readable extension and size without delivery mechanics", () => {
  const html = renderToStaticMarkup(<AttachmentStrip attachments={[file]} onRemove={() => {}} />);
  expect(html).not.toContain("Sent as file path");
  expect(html).toContain('data-file-type="pem"');
  expect(html).toContain('class="acpmux-file-chip__tail"');
  expect(html).toContain("key.pem");
  expect(html).toContain("2 kB");
  expect(html).toContain(`title="${file.path}"`);
  expect(html.replace(/<[^>]*>/g, "")).toContain(file.name);
});

test("a sent file uses the same chip and keeps the original metadata", () => {
  const html = renderToStaticMarkup(
    <UserBubble
      row={{
        id: "file-row",
        version: 1,
        at: 1,
        kind: "user",
        text: "Use this key",
        inlineParts: [
          { kind: "file", name: file.name, mimeType: file.mimeType, size: file.size, uri: `file://${file.path}` },
        ],
      }}
      text="Use this key"
    />,
  );
  expect(html).toContain('data-file-type="pem"');
  expect(html).toContain("key.pem");
  expect(html).toContain("2 kB");
  expect(html).not.toContain("Sent as file path");
});

test("legacy strip images retain only their thumbnail, alongside a real file chip", () => {
  const html = renderToStaticMarkup(
    <UserBubble
      row={{
        id: "legacy-image",
        version: 1,
        at: 1,
        kind: "user",
        inlineParts: [
          { kind: "image", id: "durable", name: "shot.png", mimeType: "image/png" },
          { kind: "file", name: "original.heic", uri: "file:///tmp/original.heic" },
          { kind: "file", name: file.name, uri: `file://${file.path}`, mimeType: file.mimeType, size: file.size },
        ],
      }}
      text="Use these"
    />,
  );
  expect(html.match(/class="acpmux-file-chip"/g)?.length).toBe(1);
  expect(html).toContain('data-file-type="pem"');
  expect(html).not.toContain('data-file-type="heic"');
});

test("the tooltip decodes the actual local path, including reserved characters", () => {
  expect(attachmentPath("file:///tmp/key%23prod%25%3F.pem")).toBe("/tmp/key#prod%?.pem");
});
