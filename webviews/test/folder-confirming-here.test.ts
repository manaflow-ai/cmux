import { expect, test } from "bun:test";
import { folderConfirmingHere } from "../src/agent-session/acpmux/useFolderTrustAsk";

// Review at b02507d7 (P2): a fresh chat has no session id, so one fresh chat's folder answer
// saving held every other fresh chat shown meanwhile. The visit tells them apart.
test("a saving folder answer holds only the visit it was asked in", () => {
  const confirming = { visit: JSON.stringify([3, null]) };
  expect(folderConfirmingHere(confirming, undefined, JSON.stringify([3, null]))).toBe(true);
  expect(folderConfirmingHere(confirming, undefined, JSON.stringify([4, null]))).toBe(false);
  expect(folderConfirmingHere(confirming, "chat-b", JSON.stringify([3, null]))).toBe(false);
});

test("with no client visit (a gallery frame), the session id alone scopes it", () => {
  expect(folderConfirmingHere({ sessionId: "chat-a" }, "chat-a", undefined)).toBe(true);
  expect(folderConfirmingHere({ sessionId: "chat-a" }, "chat-b", undefined)).toBe(false);
  expect(folderConfirmingHere(false, "chat-a", undefined)).toBe(false);
});
