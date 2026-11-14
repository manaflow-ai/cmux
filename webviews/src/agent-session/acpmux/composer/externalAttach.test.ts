import { expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import { composerReadback, externalFiles, takeExternalFiles } from "./externalAttach";

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

test("the host's files become Files with their names, types and bytes", async () => {
  const [file, ...rest] = externalFiles({ files: [{ name: "Screenshot 1.png", type: "image/png", data: PNG }] });
  expect(rest).toEqual([]);
  expect(file?.name).toBe("Screenshot 1.png");
  expect(file?.type).toBe("image/png");
  const bytes = new Uint8Array(await file!.arrayBuffer());
  expect(bytes.length).toBe(atob(PNG).length);
  expect(String.fromCharCode(...bytes.slice(1, 4))).toBe("PNG");
});

test("an entry without a name or base64 data is left out, and an older host's answer is none", () => {
  expect(
    externalFiles({
      files: [{ type: "image/png", data: PNG }, { name: "a.png", data: "%%%" }, { name: "b.png" }, null],
    }),
  ).toEqual([]);
  for (const answer of [undefined, null, {}, { files: "x" }]) expect(externalFiles(answer)).toEqual([]);
});

test("the page takes the files with chat.attach.external, and a refusal is none", async () => {
  const asked: string[] = [];
  const files = await takeExternalFiles(async (method) => {
    asked.push(method);
    return { files: [{ name: "x.png", type: "image/png", data: PNG }] };
  });
  expect(asked).toEqual(["chat.attach.external"]);
  expect(files.map((file) => file.name)).toEqual(["x.png"]);
  expect(
    await takeExternalFiles(async () => {
      throw new Error("cmux.protocol.unknown_op");
    }),
  ).toEqual([]);
});

test("the readback is the contract chat.composer.get answers", () => {
  const chip = (name: string, source?: string): ComposerAttachment => ({
    id: name,
    kind: "image",
    name,
    mimeType: "image/png",
    size: 1234,
    ...(source ? { source: { name: source, bundleId: "com.apple.screenshot.launcher" } } : {}),
  });
  expect(composerReadback({ text: "look", attachments: [chip("a.png", "Screenshot"), chip("b.png")] })).toEqual({
    text: "look",
    attachments: [
      { name: "a.png", mimeType: "image/png", bytes: 1234, source: "Screenshot" },
      { name: "b.png", mimeType: "image/png", bytes: 1234, source: "" },
    ],
  });
});
