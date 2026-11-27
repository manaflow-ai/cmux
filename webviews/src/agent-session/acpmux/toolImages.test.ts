// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "./model";
import { MAX_TOOL_IMAGES, toolImages } from "./toolImages";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const completed = (fields: Partial<Tool>): Tool => ({
  id: "audio-tool",
  title: "Write",
  kind: "edit",
  status: "completed",
  ...fields,
});

const sources: Record<string, (path: string) => Partial<Tool>> = {
  "edited path": (path) => ({ inputSummary: JSON.stringify({ file_path: path }) }),
  location: (path) => ({ locations: [{ path }] }),
  "printed output": (path) => ({ kind: "execute", command: "render-audio", output: `Saved ${path}\n` }),
};

for (const [source, fields] of Object.entries(sources)) {
  for (const suffix of ["mp3", "m4a", "aac", "wav", "flac"]) {
    for (const extension of [suffix, suffix.toUpperCase()]) {
      test(`discovers ${extension} audio from a completed tool's ${source}`, () => {
        const path = `/project/out/voice.${extension}`;
        expect(toolImages(completed(fields(path)))).toEqual([path]);
      });
    }
  }
}

test("unfinished calls do not expose audio paths before completion", () => {
  const path = "/project/out/voice.wav";
  const fields = {
    inputSummary: JSON.stringify({ file_path: path }),
    locations: [{ path }],
    output: `Saved ${path}`,
  };
  for (const status of ["pending", "in_progress"]) {
    expect(toolImages(completed({ ...fields, status }))).toEqual([]);
  }
  expect(toolImages(completed(fields))).toEqual([path]);
});

test("one audio file reported through every source appears once", () => {
  const path = "/project/out/voice.wav";
  expect(
    toolImages(
      completed({
        images: [path],
        inputSummary: JSON.stringify({ file_path: path }),
        locations: [{ path }],
        output: `Saved ${path}\nAgain: ${path}`,
      }),
    ),
  ).toEqual([path]);
});

test("audio discovery preserves image, PDF and video files", () => {
  for (const suffix of ["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "mp4", "m4v", "mov", "webm"]) {
    const path = `/project/out/result.${suffix}`;
    for (const fields of Object.values(sources)) {
      expect(toolImages(completed(fields(path)))).toEqual([path]);
    }
  }
  for (const suffix of ["heic", "tif", "tiff", "bmp"]) {
    const path = `/project/out/result.${suffix}`;
    expect(toolImages(completed({ locations: [{ path }] }))).toEqual([path]);
  }
});

test("nonmedia, relative files and remote URLs are not discovered as local audio", () => {
  for (const path of [
    "/project/notes.txt",
    "/project/voice.wavbackup",
    "/project/voice.wav-backup",
    "out/voice.wav",
    "https://example.test/voice.wav",
  ]) {
    for (const fields of Object.values(sources)) {
      expect(toolImages(completed(fields(path)))).toEqual([]);
    }
  }
  expect(toolImages(completed({ locations: [{ path: "/project/voice.wav.bak" }] }))).toEqual([]);
});

test("quoted and bracketed audio output paths retain their absolute path", () => {
  const paths = ["/project/one.wav", "/project/two.mp3", "/project/three.flac"];
  expect(toolImages(completed({ output: `Saved "${paths[0]}"; [${paths[1]}] (${paths[2]}).` }))).toEqual(paths);
});

test("audio files share the existing per-tool media limit", () => {
  const paths = Array.from({ length: MAX_TOOL_IMAGES + 2 }, (_, index) => `/project/voice-${index}.wav`);
  expect(toolImages(completed({ locations: paths.map((path) => ({ path })) }))).toEqual(
    paths.slice(0, MAX_TOOL_IMAGES),
  );
});

test("a read that returned its image shows that image, not its path again", () => {
  const path = "/tmp/ux-after-light.png";
  const image = "data:image/png;base64,iVBORw0KGgo=";
  const read = (fields: Partial<Tool>): Tool =>
    completed({
      title: "Read",
      kind: "read",
      inputSummary: JSON.stringify({ file_path: path }),
      locations: [{ path }],
      ...fields,
    });
  expect(toolImages(read({ images: [image] }))).toEqual([image]);
  // No image came back (an older daemon, a result past the size cap): the path, as before.
  expect(toolImages(read({}))).toEqual([path]);
});
