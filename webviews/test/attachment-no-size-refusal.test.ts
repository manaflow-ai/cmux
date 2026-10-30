// Leo: "Attachments take arbitrarily large files of any type; there is no size cap."
import { expect, test } from "bun:test";
import { promptBlocks, recordingAttachment } from "../src/agent-session/acpmux/attachments";
import { intakeFiles } from "../src/agent-session/acpmux/composer/intakeFiles";

for (const [name, type] of [
  ["large.pdf", "application/pdf"],
  ["large.txt", "text/plain"],
  ["large.wav", "audio/wav"],
  ["large.heic", "image/heic"],
]) {
  test(`${name}: an original over 5 GiB streams as a file without reading its body`, async () => {
    const file = new File([], name, { type });
    Object.defineProperty(file, "size", { value: 5 * 1024 ** 3 + 1 });
    Object.defineProperty(file, "arrayBuffer", {
      value: () => {
        throw new Error("original read in page");
      },
    });
    let uploaded: File[] = [];
    const result = await intakeFiles([file], {
      allowImages: true,
      upload: async (files) => {
        uploaded = files;
        return { paths: [`/session/${name}`] };
      },
    });
    expect(uploaded).toEqual([file]);
    expect(result.error).toBeUndefined();
    expect(result.attachments).toHaveLength(1);
    expect(result.attachments[0]).toMatchObject({
      kind: "link",
      path: `/session/${name}`,
      size: file.size,
    });
    expect(promptBlocks("read this", result.attachments)).toContainEqual({
      type: "resource_link",
      uri: `file:///session/${name}`,
      name,
    });
  });
}

test("an older host's recording above 4 MiB uploads intact instead of being omitted", async () => {
  const bytes = 4 * 1024 ** 2 + 1;
  const audio = { mimeType: "audio/wav", data: "AAAA".repeat(Math.floor(bytes / 3)) + "AAA=" };
  let saved: File | undefined;
  const chip = await recordingAttachment(audio, "Voice recording", false, async (file: File) => {
    saved = file;
    return "/session/recording.wav";
  });
  expect(saved?.size).toBe(bytes);
  expect(chip).toMatchObject({
    kind: "link",
    saved: true,
    path: "/session/recording.wav",
    size: bytes,
  });
  expect(promptBlocks("words", [chip!]).some((block) => block.type === "audio")).toBe(false);
});

test("an upload failure preserves the original failure instead of silently dropping audio", async () => {
  const audio = { mimeType: "audio/wav", data: "AAAA".repeat(1_400_000) };
  await expect(
    recordingAttachment(audio, "Voice recording", false, async () => {
      throw new Error("disk full");
    }),
  ).rejects.toThrow("disk full");
});
