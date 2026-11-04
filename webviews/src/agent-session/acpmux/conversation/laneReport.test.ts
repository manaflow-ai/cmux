import { expect, test } from "bun:test";
import { laneNotice } from "./laneReport";

test("inbox notice strips the harness wrapper and keeps each delivery preview", () => {
  const text = [
    "New messages from other agents in 2 threads. They need no turn of your own: read a thread whole with the inbox_read tool.",
    "- 1 new in #29626 from stranded-composer-land: merged #29626 (thread from:strand/pr:29626)",
    '- 2 new in "coord" from origin-assist, pane-tools (thread topic:coord):',
    "> origin-assist: ready for review",
    "> pane-tools: checks are green",
  ].join("\n");
  const parsed = laneNotice({ name: "inbox", text, raw: `[inbox] ${text}` });
  expect(parsed).toMatchObject({ kind: "inbox", preview: "stranded-composer-land, pane-tools" });
  if (parsed?.kind !== "inbox") return;
  expect(parsed.threads).toEqual([
    {
      id: "from:strand/pr:29626",
      sender: "stranded-composer-land",
      preview: "merged #29626",
      messages: [{ sender: "stranded-composer-land", text: "merged #29626" }],
    },
    {
      id: "topic:coord",
      sender: "pane-tools",
      preview: "checks are green",
      messages: [
        { sender: "origin-assist", text: "ready for review" },
        { sender: "pane-tools", text: "checks are green" },
      ],
    },
  ]);
  // Keep the raw body for the disclosure panel; the renderer strips wrapper text when it
  // expands the notice into message rows.
  expect(parsed.body).toContain("inbox_read");
});
