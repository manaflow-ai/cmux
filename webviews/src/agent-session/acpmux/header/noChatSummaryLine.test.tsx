// The chat header draws no rolling summary line ("Tests pass → Open the PR") beside the chat's name
// or in the tab row (https://github.com/manaflow-ai/cmux/issues/51749: the user did not want it, so
// the line, its acpmux `rollingSummary` field and every surface that drew it are gone).
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { ChatHeaderInlineStatus } from "./ChatHeaderStatus";

test("the tab row's inline slot draws nothing for a healthy chat", () => {
  expect(renderToStaticMarkup(<ChatHeaderInlineStatus status="" />)).toBe("");
});

test("no agent pane source draws a chat's rolling summary", () => {
  const root = join(import.meta.dir, "..");
  const offenders: string[] = [];
  const walk = (dir: string) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (/\.(tsx?|css)$/.test(path) && path !== join(import.meta.dir, "noChatSummaryLine.test.tsx")) {
        const source = readFileSync(path, "utf8");
        for (const marker of ["rollingSummary", "ChatSummaryLine", "acpmux-chat-summary", "data-chat-summary"])
          if (source.includes(marker)) offenders.push(`${path.slice(root.length + 1)}: ${marker}`);
      }
    }
  };
  walk(root);
  expect(offenders).toEqual([]);
}, 30_000);
