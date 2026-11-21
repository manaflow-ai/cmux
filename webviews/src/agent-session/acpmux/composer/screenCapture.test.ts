// Leo, 2026-11-07 (ask-b640c4d6fa): "could we also have a more native screenshot/screensharer
// (ergonomic one)/video recording of the app type thing/route?"
import { expect, test } from "bun:test";
import { sourceOfFile } from "../attachments";
import { takeCapture } from "./screenCapture";

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const MOVIE = "/Users/dev/Movies/cmux/Screen Recording 2026-11-10 10.02.11.mov";

test("a recording goes in as a video link chip by the path the host kept it at, wearing cmux", async () => {
  const asked: unknown[] = [];
  const taken = await takeCapture(
    "video",
    async (method, params) => {
      asked.push([method, params]);
      return { path: MOVIE, name: "Screen Recording 2026-11-10 10.02.11.mov", source: { name: "cmux" } };
    },
    () => "chat-a",
  );
  expect(asked).toEqual([["composer.capture", { mode: "video" }]]);
  expect(taken?.kind).toBe("recording");
  if (taken?.kind !== "recording") return;
  expect(taken.attachment).toMatchObject({
    kind: "link",
    path: MOVIE,
    name: "Screen Recording 2026-11-10 10.02.11.mov",
  });
  expect(taken.attachment.source).toEqual({ name: "cmux" });
});

test("a still from the recording toolbar goes in as an image", async () => {
  const taken = await takeCapture(
    "video",
    async () => ({ name: "Screenshot.png", mimeType: "image/png", data: PNG, source: { name: "cmux" } }),
    () => "chat-a",
  );
  expect(taken?.kind).toBe("still");
  if (taken?.kind !== "still") return;
  expect(taken.file.type).toBe("image/png");
  expect(sourceOfFile(taken.file)).toEqual({ name: "cmux" });
});

test("a capture answered after the pane moved to another chat goes nowhere", async () => {
  let shown = "chat-a";
  for (const answer of [{ path: MOVIE }, { name: "Screenshot.png", mimeType: "image/png", data: PNG }]) {
    shown = "chat-a";
    const taken = await takeCapture(
      answer.path ? "video" : "screen",
      async () => {
        shown = "chat-b";
        return answer;
      },
      () => shown,
    );
    expect(taken).toBeUndefined();
  }
});

test("a cancel, a failure or a path where only a still is asked for attaches nothing", async () => {
  expect(
    await takeCapture(
      "video",
      async () => ({ cancelled: true }),
      () => "a",
    ),
  ).toBeUndefined();
  expect(
    await takeCapture(
      "video",
      () => Promise.reject(new Error("capture.failed")),
      () => "a",
    ),
  ).toBeUndefined();
  expect(
    await takeCapture(
      "screen",
      async () => ({ path: MOVIE }),
      () => "a",
    ),
  ).toBeUndefined();
  expect(
    await takeCapture(
      "video",
      async () => ({ path: "relative.mov" }),
      () => "a",
    ),
  ).toBeUndefined();
});
