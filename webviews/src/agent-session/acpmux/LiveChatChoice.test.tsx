import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LiveChatChoice } from "./LiveChatChoice";

// A Claude Code chat still open in a terminal: the line says so, names the process, and offers both ways on.
test("a live Claude Code chat names its process and offers Fork It and Open Anyway", () => {
  const html = renderToStaticMarkup(
    <LiveChatChoice canFork command="claude --resume 0a1b2c3d" onChoose={() => undefined} />,
  );
  expect(html).toContain("This chat is still open in another process.");
  expect(html).toContain('<code class="acpmux-live-chat-command">claude --resume 0a1b2c3d</code>');
  expect(html).toContain(">Fork It</button>");
  expect(html).toContain(">Open Anyway</button>");
});

// Codex chats don't fork on adopt, and a recent write names no process.
test("a live Codex chat offers only Open Anyway", () => {
  const html = renderToStaticMarkup(<LiveChatChoice canFork={false} onChoose={() => undefined} />);
  expect(html).not.toContain("Fork It");
  expect(html).not.toContain("<code");
  expect(html).toContain(">Open Anyway</button>");
});
