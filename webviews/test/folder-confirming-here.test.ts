import { expect, test } from "bun:test";
import { inThisVisit, visitOf } from "../src/agent-session/acpmux/useFolderTrustAsk";

// Review at b02507d7 (P2): a fresh chat has no session id, so one fresh chat's folder answer
// saving held every other fresh chat shown meanwhile. The visit tells them apart.
test("a saving folder answer holds only the visit it was asked in", () => {
  const confirming = { visit: JSON.stringify([3, null]) };
  expect(inThisVisit(confirming, undefined, JSON.stringify([3, null]))).toBe(true);
  expect(inThisVisit(confirming, undefined, JSON.stringify([4, null]))).toBe(false);
  expect(inThisVisit(confirming, "chat-b", JSON.stringify([3, null]))).toBe(false);
});

test("with no client visit (a gallery frame), the session id alone scopes it", () => {
  expect(inThisVisit(undefined, undefined, undefined)).toBe(false);
  expect(inThisVisit({ sessionId: "chat-a" }, "chat-a", undefined)).toBe(true);
  expect(inThisVisit({ sessionId: "chat-a" }, "chat-b", undefined)).toBe(false);
  expect(inThisVisit(false, "chat-a", undefined)).toBe(false);
});

// Review at fdb422c0 (P2): a request made from a stale render (the client already moved on) must
// not show, or run its callback, in the next fresh chat.
test("a stale render's visit never matches a chat", () => {
  const stale = { ...visitOf(Symbol("stale-trust-visit")) };
  expect(stale.visit).toBeDefined();
  expect(inThisVisit(stale, undefined, JSON.stringify([5, null]))).toBe(false);
  expect(inThisVisit(stale, undefined, undefined)).toBe(false);
  expect(visitOf(undefined)).toEqual({});
  expect(visitOf("v")).toEqual({ visit: "v" });
});
