// A chat that shows a Claude Code or Codex session another app runs, without running it (acpmux
// `hub/watch.rs`, Leo 2026-10-18): the pane names the app the session runs in and offers Take Over.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { WatchBanner, watchedApp } from "../src/agent-session/acpmux/WatchBanner";

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
