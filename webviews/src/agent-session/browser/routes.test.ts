import { expect, test } from "bun:test";
import { browserChatHref, browserChatRoute } from "./routes";

const BASE = "http://localhost:4000/app/";

test("session keys, peer keys and native session turns keep their destination", () => {
  for (const session of ["session-1", "host/session-1", "aid-0123456789abcdef0123"])
    expect(browserChatRoute(`/app/?session=${encodeURIComponent(session)}`, BASE)).toEqual({ session });
  expect(browserChatRoute("cmux-nightly://session/session-1#turn-turn-2", BASE)).toEqual({
    session: "session-1",
    turn: "turn-2",
  });
});

test("public and native agent links use the daemon's resolver with routing fields only", () => {
  for (const href of [
    "cmux://agent/codex/agent-1?host=remote&message=row-1&token=secret",
    "https://www.cmux.com/en/deeplink/agent/?harness=codex&session=agent-1&host=remote&message=row-1&token=secret#token=secret",
  ]) {
    const route = browserChatRoute(href, BASE);
    expect(route).toEqual({
      session: "https://cmux.com/deeplink/agent?harness=codex&session=agent-1&host=remote",
      message: "row-1",
    });
    expect(browserChatHref(route!)).not.toContain("secret");
    expect(browserChatRoute(browserChatHref(route!), BASE)).toEqual(route);
  }
  expect(browserChatRoute("https://cmux.com/deeplink/agent?id=aid-0123456789abcdef0123", BASE)).toEqual({
    session: "https://cmux.com/deeplink/agent?id=aid-0123456789abcdef0123",
  });
});

test("launch credentials and transport query fields never become navigation", () => {
  const route = browserChatRoute(`${BASE}?session=s1&endpoint=wss://other&token=secret#token=secret`, BASE);
  expect(route).toEqual({ session: "s1" });
  expect(browserChatHref(route!)).toBe("/app/?session=s1");
});

test("foreign origins, malformed destinations and unsupported native surfaces stay unhandled", () => {
  for (const href of [
    "https://other.test/app/?session=s1",
    "https://cmux.com.evil.test/deeplink/agent?harness=codex&session=s1",
    "/app/?session=s1&session=s2",
    "/app/?session=..",
    "/app/?session=https%3A%2F%2Fevil.test",
    "https://user:pass@localhost:4000/app/?session=s1",
    "cmux://workspace/ws_0123456789abcdef0123456789abcdef",
    "cmux://chief/01234567/session/s1",
    "javascript:alert(1)",
    " /app/?session=s1",
    "/app/other?session=s1",
    "https://cmux.com/deeplink/agent?harness=codex&session=s1&session=s2",
  ])
    expect(browserChatRoute(href, BASE)).toBeUndefined();
});
