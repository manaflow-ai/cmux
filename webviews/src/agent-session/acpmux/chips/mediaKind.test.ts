// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import { mediaKind } from "./mediaKind";

test("classifies playable audio and video without loading a player", () => {
  for (const extension of ["mp3", "m4a", "aac", "wav", "flac"]) {
    expect(mediaKind(`/project/sound.${extension}`)).toBe("audio");
    expect(mediaKind(`/project/sound.${extension.toUpperCase()}`)).toBe("audio");
  }
  for (const extension of ["mp4", "m4v", "mov", "webm"]) {
    expect(mediaKind(`/project/movie.${extension}`)).toBe("video");
  }
  for (const path of ["/project/image.png", "/project/sound.wav.bak", "/project/readme.md"]) {
    expect(mediaKind(path)).toBeUndefined();
  }
});

test("media classification retains file URLs and link suffix normalization", () => {
  expect(mediaKind("file:///project/voice%20note.M4A")).toBe("audio");
  expect(mediaKind("/project/sound.wav:12")).toBe("audio");
  expect(mediaKind("/project/sound.wav?download=1#preview")).toBe("audio");
  expect(mediaKind("https://example.test/movie.mp4?token=fixture#preview")).toBe("video");
});
