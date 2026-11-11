// A page's `action.run` the app refused says the app's reason in the pane's toast. Move to Cloud on a
// chat with no first message and Bring Back Local on a chat no move put on Cloud were refused with a
// reason ("Send a first message, then move this chat."), and the person saw nothing happen.
import { afterEach, expect, test } from "bun:test";
import { actionRefusal, sayActionRefusal } from "./actionRefusal";
import { offloadReasonsOf } from "./environments";
import { headerState, resetHeaderStateForTests, setHeaderState } from "./header/headerState";
import { NativeError } from "./nativeError";

// The header pushes below reach version 4; a later file starts the header from version 0 again.
afterEach(() => resetHeaderStateForTests());

const reason = "Send a first message, then move this chat.";
const refused = (details: unknown, code = "unavailable") =>
  new NativeError({ code, userMessage: typeof details === "object" ? reason : "x", details, origin: "native" });

test("the app's refusal reason is read from an unavailable reply's details", () => {
  expect(actionRefusal(refused({ reason }))).toBe(reason);
  expect(actionRefusal(refused({ reason: "  " }))).toBeUndefined();
  expect(actionRefusal(refused(undefined))).toBeUndefined();
  expect(actionRefusal(refused({ reason }, "gesture_required"))).toBeUndefined();
  expect(actionRefusal(new Error(reason))).toBeUndefined();
});

test("a refused run says the reason, else the fallback, and never an empty toast", () => {
  const said: string[] = [];
  const say = (text: string) => said.push(text);
  sayActionRefusal(say, () => "Couldn't start Move to Cloud")(refused({ reason }));
  sayActionRefusal(say, () => "Couldn't start Move to Cloud")(refused(undefined));
  sayActionRefusal(say)(refused(undefined));
  sayActionRefusal(say, () => "")(refused({ reason: "" }));
  expect(said).toEqual([reason, "Couldn't start Move to Cloud"]);
});

test("pane.tabState's moveReasons reach the offered moves by kind", () => {
  setHeaderState({ moves: ["cloudMove"], moveReasons: { cloudMove: reason, cloudBringBack: 3 }, version: 1 });
  expect(headerState().moveReasons).toEqual({ cloudMove: reason });
  expect(offloadReasonsOf(["move"], headerState().moveReasons)).toEqual({ move: reason });
  // A reply that names the moves and no reasons offers them all again.
  setHeaderState({ moves: ["cloudMove"], version: 2 });
  expect(offloadReasonsOf(["move"], headerState().moveReasons)).toEqual({});
  // A push without moves keeps both.
  setHeaderState({ moves: ["cloudMove"], moveReasons: { cloudMove: reason }, version: 3 });
  setHeaderState({ pinned: true, version: 4 });
  expect(headerState().moveReasons).toEqual({ cloudMove: reason });
});
