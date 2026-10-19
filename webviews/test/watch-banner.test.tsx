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
