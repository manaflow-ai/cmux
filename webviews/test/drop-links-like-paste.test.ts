// Leo, 2026-11-17: pasting a copied file was instant, dragging the same file from a Finder folder
// was slow. A drop on a chat on this Mac takes the paste's route: the host says where the files
// are (`chat.attach.dropped`) and each goes as a link to its path, with no bytes read, encoded,
// hashed or uploaded, whatever its size. The host refuses a chat not on this Mac.
import { expect, test } from "bun:test";
import { droppedPaths, intakeFiles } from "../src/agent-session/acpmux/composer/intakeFiles";

const MB = 1024 * 1024;

/// A 500 MB file as WebKit hands a Finder drop: its size is declared, and any read of its bytes is
/// counted (a link never reads one).
function bigFile(name: string, reads: string[]): File {
  const file = new File([], name, { type: "application/zip" });
  Object.defineProperty(file, "size", { value: 500 * MB });
  for (const method of ["arrayBuffer", "text", "stream", "bytes"] as const)
    Object.defineProperty(file, method, {
      value: () => {
        reads.push(method);
        throw new Error(`read ${method}`);
      },
    });
  Object.defineProperty(file, "slice", {
    value: () => {
      reads.push("slice");
      throw new Error("read slice");
    },
  });
  return file;
}

test("a drop on a local chat links a 500 MB file by its path at once, with no upload", async () => {
  const reads: string[] = [];
  const asked: [string, Record<string, unknown>][] = [];
  const uploads: File[][] = [];
  const file = bigFile("dataset.zip", reads);
  // The host's record of the person's drop (AgentPaneDroppedPaths), answered from memory.
  const call = async (method: string, params: Record<string, unknown>) => {
    asked.push([method, params]);
    return { items: [{ path: "/Users/you/Downloads/dataset.zip", folder: false }] };
  };
  const started = performance.now();
  const { attachments, error } = await intakeFiles([file], {
    allowImages: true,
    localPaths: (files) => droppedPaths("drop", files, call),
    upload: async (files) => {
      uploads.push(files);
      return { paths: files.map((each) => `/tmp/${each.name}`) };
    },
  });
  const elapsed = performance.now() - started;
  expect(error).toBeUndefined();
  expect(asked).toEqual([["chat.attach.dropped", { kind: "drop", names: ["dataset.zip"] }]]);
  expect(attachments.map((chip) => [chip.kind, chip.kind === "link" ? chip.path : undefined])).toEqual([
    ["link", "/Users/you/Downloads/dataset.zip"],
  ]);
  expect(uploads).toEqual([]);
  expect(reads).toEqual([]);
  expect(elapsed).toBeLessThan(50);
});
