import { expect, test } from "bun:test";
import { devHostParams, devHostReply } from "./devHost";

test("the fragment names a loopback daemon and its token", () => {
  expect(devHostParams("#endpoint=ws://127.0.0.1:47901/&token=abc&cwd=/repo&new")).toEqual({
    endpoint: "ws://127.0.0.1:47901/",
    token: "abc",
    sessionId: undefined,
    newSession: true,
    cwd: "/repo",
  });
});

test("a fragment without a token, a remote host or another scheme names no daemon", () => {
  expect(devHostParams("")).toBeUndefined();
  expect(devHostParams("#endpoint=ws://127.0.0.1:47901/")).toBeUndefined();
  expect(devHostParams("#endpoint=ws://example.com:47901/&token=abc")).toBeUndefined();
  expect(devHostParams("#endpoint=wss://127.0.0.1:47901/&token=abc")).toBeUndefined();
  expect(devHostParams("#endpoint=nonsense&token=abc")).toBeUndefined();
});

test("ready hands the page the daemon; native-only requests are refused", () => {
  const host = { endpoint: "ws://127.0.0.1:47901/", token: "abc", sessionId: "s1" };
  expect(devHostReply(host, { id: "1", method: "ready" })).toMatchObject({
    ok: true,
    value: { transport: "acpmux-websocket", endpoint: host.endpoint, token: "abc", sessionId: "s1" },
  });
  expect(devHostReply(host, { id: "2", method: "git.status" })).toMatchObject({
    ok: false,
    error: { code: "native.unsupported" },
  });
});
