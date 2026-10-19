// A chat that shows a Claude Code or Codex session another app runs, without running it (acpmux
// `hub/watch.rs`, Leo 2026-10-18): the pane names the app the session runs in and offers Take Over.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { WatchBanner, watchGoBack, watchResumeFailed, watchedApp } from "../src/agent-session/acpmux/WatchBanner";

test("the banner names the app the watched session runs in and offers Take Over", () => {
  const html = renderToStaticMarkup(<WatchBanner family="claude" onTakeOver={() => {}} />);
  expect(html).toContain("Viewing Claude Code session");
  expect(html).toContain("Take Over");
  expect(renderToStaticMarkup(<WatchBanner family="codex" onTakeOver={() => {}} />)).toContain("Viewing Codex session");
});

test("an unknown family is named as acpmux reports it", () => {
  expect(watchedApp("opencode")).toBe("opencode");
});

// Viewing never blocks starting a session (Leo 2026-10-19): the banner always offers a way on.
test("the banner offers a new chat from the viewed session", () => {
  const claude = renderToStaticMarkup(<WatchBanner family="claude" onTakeOver={() => {}} onContinue={() => {}} />);
  expect(claude).toContain("Continue in New Chat");
  const codex = renderToStaticMarkup(<WatchBanner family="codex" onTakeOver={() => {}} onContinue={() => {}} />);
  expect(codex).toContain("New Chat Here");
});

// View Only is what you get when you don't act: the composer stays on, and a reply takes over.
test("the banner says a reply takes the session over", () => {
  expect(renderToStaticMarkup(<WatchBanner family="codex" onTakeOver={() => {}} />)).toContain(
    "Reply to take over this session",
  );
});

// Going back (Leo 2026-10-19): after a take-over the transcript says how the original app goes on.
test("a take-over says how to continue in the original app", () => {
  const claude = watchGoBack({ family: "claude", agentSessionId: "abc", cwd: "/Users/me/my project" });
  expect(claude).toContain("Claude Code");
  expect(claude).toContain("cd '/Users/me/my project' && claude --resume abc");
  const codex = watchGoBack({ family: "codex", agentSessionId: "019a", cwd: "/w" });
  expect(codex).toContain("cd /w && codex resume 019a");
  const fork = watchGoBack({ family: "claude", agentSessionId: "abc", cwd: "/w", fork: true });
  expect(fork).toContain("untouched");
  expect(watchGoBack({ family: "opencode", agentSessionId: "x", cwd: "/w" })).toBeUndefined();
  expect(watchGoBack({ family: "claude", cwd: "/w" })).toBeUndefined();
});

// A take-over whose resume fails stays View Only and says why (Leo 2026-10-19, resume unsupported).
test("a failed resume says why and that the chat stays View Only", () => {
  const line = watchResumeFailed("codex", "No such file or directory (os error 2).");
  expect(line).toContain("Codex");
  expect(line).toContain("No such file or directory (os error 2). It stays View Only");
  expect(line).toContain("View Only");
});
