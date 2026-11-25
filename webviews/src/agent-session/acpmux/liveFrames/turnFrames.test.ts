import { expect, test } from "bun:test";
import {
  frameFullParams,
  latestFrameParams,
  pictureOf,
  readFrame,
  readFrames,
  readLatest,
  turnFramesParams,
} from "./turnFrames";

const PNG = "data:image/png;base64,AAAA";

test("pictureOf takes data URLs and {mimeType, data}, nothing else", () => {
  expect(pictureOf(PNG)).toBe(PNG);
  expect(pictureOf({ mimeType: "image/jpeg", data: "QQ==" })).toBe("data:image/jpeg;base64,QQ==");
  expect(pictureOf({ data: "QQ==" })).toBe("data:image/png;base64,QQ==");
  expect(pictureOf("https://x/y.png")).toBeUndefined();
  expect(pictureOf("handle-1")).toBeUndefined();
  expect(pictureOf(null)).toBeUndefined();
});

test("readFrame falls back to the thumb when full is a handle, and drops pictureless frames", () => {
  const frame = readFrame({ index: 2, trigger: "edit", at: 5, thumb: PNG, full: "handle" });
  expect(frame?.full).toBe(PNG);
  expect(frame?.trigger).toBe("edit");
  expect(readFrame({ index: 1 })).toBeUndefined();
  expect(readFrame("x")).toBeUndefined();
});

test("readFrames orders, dedupes by index and tolerates junk", () => {
  const frames = readFrames({
    frames: [{ index: 3, thumb: PNG }, { index: 1, thumb: PNG }, { index: 3, thumb: PNG, trigger: "last" }, null],
  });
  expect(frames.map((f) => f.index)).toEqual([1, 3]);
  expect(frames[1].trigger).toBe("last");
  expect(readFrames(undefined)).toEqual([]);
  expect(readFrames({ frames: "no" })).toEqual([]);
});

test("readLatest returns the newest frame and the next seq", () => {
  const got = readLatest(
    {
      frames: [
        { index: 1, thumb: PNG },
        { index: 2, thumb: PNG },
      ],
      seq: 9,
    },
    4,
  );
  expect(got.frame?.index).toBe(2);
  expect(got.seq).toBe(9);
  expect(readLatest({}, 4)).toEqual({ frame: undefined, seq: 4 });
});

test("request params", () => {
  expect(turnFramesParams("s", "t")).toEqual({ sessionId: "s", turnId: "t" });
  expect(latestFrameParams("s", 3)).toEqual({ sessionId: "s", sinceSeq: 3 });
  expect(frameFullParams("s", "t", 2)).toEqual({ sessionId: "s", turnId: "t", index: 2 });
});
