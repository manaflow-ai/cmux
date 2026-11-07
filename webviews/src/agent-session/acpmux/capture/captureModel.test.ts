// The capture bar's state (captureModel.ts): the shortcut opens, closes or stops; a capture closes
// the bar; closing never drops a recording; a failed start keeps the choices.
import { expect, test } from "bun:test";
import {
  captureReducer,
  elapsedLabel,
  INITIAL_CAPTURE,
  parseRecording,
  reopen,
  toggleMeaning,
  type CaptureEvent,
  type CaptureState,
} from "./captureModel";

const run = (events: CaptureEvent[], from: CaptureState = INITIAL_CAPTURE) => events.reduce(captureReducer, from);

test("the shortcut opens a closed bar and closes an open one", () => {
  expect(run([{ type: "toggle" }]).phase).toEqual({ kind: "open" });
  expect(run([{ type: "toggle" }, { type: "toggle" }]).phase).toEqual({ kind: "closed" });
});

test("a screenshot closes the bar once the host answers, keeping the destination for next time", () => {
  const state = run([
    { type: "toggle" },
    { type: "destination", destination: "copy" },
    { type: "begin", what: "window" },
  ]);
  expect(state.phase).toEqual({ kind: "busy", what: "window" });
  // The shortcut does nothing while the pick is out.
  expect(toggleMeaning(state.phase)).toBe("wait");
  const done = captureReducer(state, { type: "done" });
  expect(done.phase).toEqual({ kind: "closed" });
  expect(done.destination).toBe("copy");
});

test("while recording, the shortcut stops it, and Close or Esc never drops it", () => {
  const recording = run([{ type: "toggle" }, { type: "begin", what: "record" }, { type: "recording", at: 1000 }]);
  expect(recording.phase).toEqual({ kind: "recording", startedAt: 1000 });
  expect(captureReducer(recording, { type: "close" }).phase.kind).toBe("recording");
  expect(toggleMeaning(recording.phase)).toBe("stop");
  const finishing = captureReducer(recording, { type: "toggle" });
  expect(finishing.phase).toEqual({ kind: "finishing" });
  expect(captureReducer(finishing, { type: "done" }).phase).toEqual({ kind: "closed" });
});

test("a recording answer for another start is ignored; a failed start reopens with the choices", () => {
  const open = run([{ type: "toggle" }, { type: "option", option: "clicks", on: false }]);
  expect(captureReducer(open, { type: "recording", at: 5 })).toBe(open);
  const busy = captureReducer(open, { type: "begin", what: "record" });
  const again = reopen(busy);
  expect(again.phase).toEqual({ kind: "open" });
  expect(again.clicks).toBe(false);
});

test("elapsed reads m:ss", () => {
  expect(elapsedLabel(0)).toBe("0:00");
  expect(elapsedLabel(65_400)).toBe("1:05");
  expect(elapsedLabel(-10)).toBe("0:00");
});

test("a recording answer needs an absolute movie path", () => {
  expect(parseRecording({ path: "/tmp/Recording 1.mp4", name: "Recording 1.mp4", seconds: 4.2 })).toEqual({
    path: "/tmp/Recording 1.mp4",
    name: "Recording 1.mp4",
    seconds: 4.2,
  });
  expect(parseRecording({ path: "/tmp/x.mp4" })?.name).toBe("x.mp4");
  expect(parseRecording({ path: "relative.mp4" })).toBeUndefined();
  expect(parseRecording({ path: "/etc/passwd" })).toBeUndefined();
  expect(parseRecording({ cancelled: true })).toBeUndefined();
  expect(parseRecording(null)).toBeUndefined();
});
