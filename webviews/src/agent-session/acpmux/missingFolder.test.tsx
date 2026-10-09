import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { MissingFolder, chooseChatFolder } from "./missingFolder";

// cx-nn3e.1: a chat whose folder was deleted opened a bare macOS Open panel with no explanation.
// The chat opens in its pane; one line above the composer says why and offers Choose Folder. The
// pick re-opens the chat there (`chat.folder.choose`): a resumable chat is adopted at once.

test("the line explains the missing folder and offers Choose Folder", () => {
  const html = renderToStaticMarkup(
    <MissingFolder reason="the chat's folder /old was deleted or moved; pick one" onChoose={() => undefined} />,
  );
  expect(html).toContain("This chat’s folder isn’t available.");
  expect(html).toContain("the chat&#x27;s folder /old was deleted or moved; pick one");
  expect(html).toContain(">Choose Folder…</button>");
});

test("a picked folder resumes the chat in this pane", async () => {
  const resumed: unknown[] = [];
  const result = await chooseChatFolder(
    async () => ({ adopt: { harness: "claude", agentSessionId: "abc" }, cwd: "/new" }),
    async (adopt) => {
      resumed.push(adopt);
    },
  );
  expect(result).toEqual({ done: true });
  expect(resumed).toEqual([{ harness: "claude", agentSessionId: "abc" }]);
});

test("a pick that is still not a folder keeps the line with the new reason", async () => {
  const resumed: unknown[] = [];
  const result = await chooseChatFolder(
    async () => ({ reason: "cwd /tmp/x is not a folder" }),
    async (adopt) => {
      resumed.push(adopt);
    },
  );
  expect(result).toEqual({ reason: "cwd /tmp/x is not a folder" });
  expect(resumed).toEqual([]);
});

test("a cancelled pick changes nothing", async () => {
  expect(await chooseChatFolder(async () => ({}), async () => undefined)).toEqual({});
});

test("a chat opened elsewhere (a terminal chat) is done", async () => {
  expect(await chooseChatFolder(async () => ({ opened: true }), async () => undefined)).toEqual({ done: true });
});
