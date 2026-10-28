import { expect, test } from "bun:test";
import { authBlocksSend, authText, readSessionAuth } from "../src/agent-session/acpmux/sessionAuth";

test("only explicit auth refusals block", () => {
  expect(authBlocksSend(readSessionAuth({state:"signedOut", source:"authCheck", evidenceAt:1}))).toBe(true);
  expect(authBlocksSend(readSessionAuth({state:"expired", source:"turn", evidenceAt:2}))).toBe(true);
  expect(authBlocksSend(readSessionAuth({state:"routeAuthNeeded", source:"routeProbe", evidenceAt:3}))).toBe(true);
  expect(authBlocksSend(readSessionAuth({state:"unknown", source:"none", evidenceAt:null}))).toBe(false);
  expect(authBlocksSend(readSessionAuth({state:"routeUnreachable", source:"peerLink", evidenceAt:4}))).toBe(false);
  expect(authBlocksSend(readSessionAuth({state:"peerUnreachable", source:"peerLink", evidenceAt:5}))).toBe(false);
});

test("invalid or missing protocol state becomes non-blocking unknown", () => {
  expect(readSessionAuth(undefined).state).toBe("unknown");
  expect(readSessionAuth({state:"signedOut", source:"none"}).state).toBe("unknown");
  expect(readSessionAuth({state:"ready", source:"turn", evidenceAt:10, fromSessionId:"s1"}).fromSessionId).toBe("s1");
});

test("auth details preserve source-specific login instructions", () => {
  const auth = readSessionAuth({
    state:"routeAuthNeeded", source:"routeProbe", evidenceAt:42,
    detail:"CLI route expired", login:{kind:"route", host:"peer-a", routeId:"r1"},
  });
  expect(authText(auth)).toContain("Route needs sign in");
  expect(auth.login).toEqual({kind:"route", host:"peer-a", routeId:"r1"});
});
