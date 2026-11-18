import { expect, test } from "bun:test";
import { autoPlaceName, autoPlaced, autoRunMode, placeChatParams, readAutoVerdict } from "./autoPlace";
import { environmentDigit } from "./environments";

// Leo, 2026-11-18: "an auto mode as an umbrella over remote/local/cloud itself. so it just goes."
test("acpmux's verdict reads as a place the page can start a chat in, or none", () => {
  expect(readAutoVerdict({ place: "local", why: "This Mac: room for 6", overloaded: false })).toEqual({
    place: "local",
    why: "This Mac: room for 6",
    overloaded: false,
  });
  expect(readAutoVerdict({ place: "peer", peer: "build-box", why: "w", reasons: [] })).toEqual({
    place: "peer",
    peer: "build-box",
    why: "w",
    overloaded: false,
  });
  expect(readAutoVerdict({ place: "cloud", overloaded: true })).toEqual({ place: "cloud", why: "", overloaded: true });
  // A peer verdict that names no machine, an unknown place, or no answer: no verdict (This Mac, said).
  expect(readAutoVerdict({ place: "peer" })).toBeUndefined();
  expect(readAutoVerdict({ place: "moon" })).toBeUndefined();
  expect(readAutoVerdict(null)).toBeUndefined();
});

test("no verdict starts the chat on This Mac and says Auto could not decide", () => {
  expect(autoPlaced(undefined)).toEqual({ place: "local", fallback: true });
  expect(autoRunMode(autoPlaced(undefined))).toBe("persistent");
  const cloud = autoPlaced({ place: "cloud", why: "Cloud: no room", overloaded: false });
  expect(autoRunMode(cloud)).toBe("cloud");
  const peer = autoPlaced({ place: "peer", peer: "build-box", why: "", overloaded: false });
  expect(peer).toEqual({ place: "peer", peer: "build-box" });
  expect(autoRunMode(peer)).toBe("persistent");
  const names = { thisMac: "This Mac", cloud: "Cloud" };
  expect(autoPlaceName(peer, names)).toBe("build-box");
  expect(autoPlaceName(cloud, names)).toBe("Cloud");
  expect(autoPlaceName(autoPlaced(undefined), names)).toBe("This Mac");
});

test("the request names the folder by path only, and Cloud's availability", () => {
  expect(placeChatParams("/Users/me/repo", true)).toEqual({ cwd: "/Users/me/repo", cloud: { available: true } });
  // No `folder` key: the pane relay reads every `folder` as a path and refuses an object there.
  expect(placeChatParams(undefined, false)).toEqual({ cloud: { available: false } });
  expect(placeChatParams("github:o/r", false)).toEqual({ cloud: { available: false } });
});

test("⌥⌘0 is Auto's key; ⌥⌘1–9 stay the machines'", () => {
  const key = (code: string) => ({ altKey: true, metaKey: true, ctrlKey: false, shiftKey: false, code });
  expect(environmentDigit(key("Digit0"))).toBe(0);
  expect(environmentDigit(key("Digit3"))).toBe(3);
  expect(environmentDigit({ ...key("Digit0"), shiftKey: true })).toBeUndefined();
});
