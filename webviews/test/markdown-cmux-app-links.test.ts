// cmux app links (`cmux://workspace/ws_…`, pane, tab, session, a Chief subagent's chat) in
// rendered Markdown: the Markdown file page follows them through the host as kind "app" (opened
// inside cmux), the agent pane draws them as links, and every other scheme stays inert.
import { expect, test } from "bun:test";
import { appHref, linkHref, safeHref } from "../src/agent-session/acpmux/replyHref";
import { MARKDOWN_OPEN_LINK_OP } from "../src/pages/markdown/host";
import { LinkRouter } from "../src/pages/markdown/linkRouter";
import { parseLink } from "../src/pages/markdown/links";

const WS = "cmux://workspace/ws_0123456789abcdef0123456789abcdef";
const APP_LINKS = [
  WS,
  "cmux://pane/pane_0123456789abcdef0123456789abcdef",
  "cmux://tab/tab_0123456789abcdef0123456789abcdef",
  "cmux://session/01a12408-f0a2-79a0-8c59-cb472f5bb9aa",
  "cmux://session/01a12408-f0a2-79a0-8c59-cb472f5bb9aa#turn-3",
  "cmux://chief/2e448bc2/session/01a12408-f0a2-79a0-8c59-cb472f5bb9aa",
  "cmux-dev-mytag://workspace/ws_0123456789abcdef0123456789abcdef",
  "cmux://agent/claude/0cfd5322-a913-4e01-b71c-aaf0edfb4de8",
  "cmux://agent/codex/019a-thread?host=build-mac&name=Lanternfish",
  `cmux://agent/claude/session:with:colon${"a".repeat(230)}`,
];
const UNSAFE = [
  "javascript:alert(1)",
  "file:///etc/passwd",
  "data:text/html,<b>x</b>",
  "vbscript:msgbox",
  "ssh://host",
  "cmux://auth-callback/x",
  "cmux://user:pw@workspace/ws_0123456789abcdef0123456789abcdef",
  "cmuxx://workspace/ws_0123456789abcdef0123456789abcdef",
];

test("the Markdown page classifies cmux app links as app links and keeps other schemes unsafe", () => {
  for (const href of APP_LINKS) expect(parseLink(href).kind).toBe("app");
  for (const href of UNSAFE) expect(parseLink(href).kind).toBe("unsafe");
  expect(parseLink("https://cmux.dev").kind).toBe("external");
  expect(parseLink(`cmux://agent/claude/${"a".repeat(256)}`).kind).toBe("app");
  expect(parseLink(`cmux://agent/claude/${"a".repeat(257)}`).kind).toBe("unsafe");
});

test("following a cmux app link on the Markdown page asks the host to open it as kind app", async () => {
  const calls: { op: string; params: unknown }[] = [];
  const client = { call: async (op: string, params: unknown) => (calls.push({ op, params }), {}) };
  const router = new LinkRouter({
    store: {
      getState: () => ({ config: { path: "/Users/me/notes.md" } }),
      navigate: async () => null,
      go: async () => null,
    } as never,
    client: client as never,
    resolver: { get: () => undefined },
    scrollToAnchor: () => false,
    scroll: { get: () => 0, set: () => {} },
  });
  await router.follow(WS);
  await router.follow("javascript:alert(1)");
  expect(calls).toEqual([{ op: MARKDOWN_OPEN_LINK_OP, params: { path: "/Users/me/notes.md", href: WS, kind: "app" } }]);
});

test("the agent pane draws cmux app links as links and nothing else that is not http(s)", () => {
  for (const href of APP_LINKS) {
    expect(appHref(href)).toBe(href);
    expect(linkHref(href)).toBe(href);
    expect(safeHref(href)).toBeUndefined();
  }
  for (const href of UNSAFE) expect(linkHref(href)).toBeUndefined();
  expect(linkHref("https://cmux.dev/")).toBe("https://cmux.dev/");
});

test("agent links keep the daemon's colon and 256-byte session grammar", () => {
  const valid = `cmux://agent/claude/${"a".repeat(256)}`;
  const tooLong = `cmux://agent/claude/${"a".repeat(257)}`;
  expect(appHref(valid)).toBe(valid);
  expect(appHref(tooLong)).toBeUndefined();
});
