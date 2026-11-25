// Detector: a file the person drops or pastes from disk is a sendable chip at once, whatever its
// size (Leo, 2026-11-22: "NO MATTER HOW FUCKING LONG THE VIDEO IS, THE PREVIEW SHOULD BE FUCKING
// INSTANT, THE POSSIBLE SEND SHOULD BE INSTANT ... IT IS LITERALLY COMING FROM FUCKING DISK ... WHAT
// THE FUCK ARE WE LOADING IT TO!?"). A file whose path the host knows goes as that path: nothing is
// streamed, copied or read in proportion to its size, so a 2 GB recording is ready as fast as a 5 MB
// one. Before, a 188 MB screen recording that reached the session's store took 128 s.
import { expect, test } from "bun:test";
import { intakeFiles } from "./intakeFiles";

/// The most a paste may take to become a sendable chip, any size.
const SENDABLE_MS = 50;
/// The most of a file intake may read before the chip is ready: a header, never the media.
const MAX_READ_BYTES = 1 << 20;

/// A file on disk of `size` bytes that WebKit hands the page: its bytes are never materialized here,
/// and every read of them is counted, so a read proportional to the file's size fails the test.
function diskFile(name: string, type: string, size: number) {
  const reads = { bytes: 0, whole: 0 };
  const slice = (start = 0, end = size): Blob => {
    const from = Math.max(0, Math.min(size, start < 0 ? size + start : start));
    const to = Math.max(from, Math.min(size, end < 0 ? size + end : end));
    const length = to - from;
    reads.bytes += length;
    if (length > MAX_READ_BYTES) throw new Error(`read ${length} bytes of ${name}`);
    return new Blob([new Uint8Array(length)], { type });
  };
  const file = {
    name,
    type,
    size,
    lastModified: 0,
    webkitRelativePath: "",
    slice,
    arrayBuffer: () => {
      reads.whole += 1;
      return Promise.reject(new Error(`read all of ${name}`));
    },
    text: () => Promise.reject(new Error(`read all of ${name}`)),
    stream: () => {
      throw new Error(`streamed ${name}`);
    },
    bytes: () => Promise.reject(new Error(`read all of ${name}`)),
  };
  return { file: file as unknown as File, reads };
}

const MB = 1024 * 1024;
const cases = [
  { name: "clip.mov", type: "video/quicktime", size: 5 * MB },
  { name: "Screen Recording 2026-11-22 at 2.11.52 AM.mov", type: "video/quicktime", size: 200 * MB },
  { name: "long take.mp4", type: "video/mp4", size: 2048 * MB },
  { name: "archive.zip", type: "application/zip", size: 2048 * MB },
];

for (const { name, type, size } of cases) {
  test(`a ${Math.round(size / MB)} MB ${name} from disk is sendable in under ${SENDABLE_MS} ms, as its path`, async () => {
    const { file, reads } = diskFile(name, type, size);
    const path = `/Users/me/Desktop/${name}`;
    let uploaded = 0;
    const started = performance.now();
    let readyAt: number | undefined;
    let chip: { kind?: string; path?: string; size?: number } | undefined;
    await intakeFiles(
      [file],
      {
        allowImages: true,
        // The host answers from its record of the drop (`chat.attach.dropped`), in memory.
        localPaths: async () => [{ path, folder: false }],
        upload: async () => {
          uploaded += 1;
          return { error: "streamed a file whose path the host knew" };
        },
      },
      {
        ready: (_index, made) => {
          readyAt ??= performance.now();
          chip = made;
        },
      },
    );
    const elapsed = (readyAt ?? Infinity) - started;
    console.info(
      `intake-speed ${name} ${Math.round(size / MB)}MB sendable_ms=${elapsed.toFixed(2)} read_bytes=${reads.bytes}`,
    );
    expect(uploaded).toBe(0);
    expect(reads.whole).toBe(0);
    expect(reads.bytes).toBeLessThanOrEqual(MAX_READ_BYTES);
    expect(chip?.kind).toBe("link");
    expect(chip?.path).toBe(path);
    expect(chip?.size).toBe(size);
    expect(elapsed).toBeLessThan(SENDABLE_MS);
  });
}

test("the time to sendable does not grow with the file's size", async () => {
  const timeFor = async (size: number) => {
    const { file } = diskFile("take.mov", "video/quicktime", size);
    const started = performance.now();
    let readyAt = Infinity;
    await intakeFiles(
      [file],
      { allowImages: true, localPaths: async () => [{ path: "/tmp/take.mov", folder: false }] },
      { ready: () => (readyAt = Math.min(readyAt, performance.now())) },
    );
    return readyAt - started;
  };
  // Warm the module paths once, then compare 5 MB against 2 GB.
  await timeFor(5 * MB);
  const small = await timeFor(5 * MB);
  const large = await timeFor(2048 * MB);
  console.info(`intake-speed scaling small_ms=${small.toFixed(2)} large_ms=${large.toFixed(2)}`);
  expect(large).toBeLessThan(SENDABLE_MS);
  expect(large - small).toBeLessThan(SENDABLE_MS / 2);
});
