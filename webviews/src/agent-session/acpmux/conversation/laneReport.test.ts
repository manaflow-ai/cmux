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

// Review of #37653: an older acpmux's suffix, "(self-declared, unauthenticated)", holds a comma, so
// a line's senders are read whole before they are split.
test("an older inbox line's unverified suffix is read before its senders are split", () => {
  const notice = (from: string) => {
    const text = `New messages from other agents in 1 thread.\n- 1 new in #5 from ${from}: hi (thread pr:5)`;
    const parsed = laneNotice({ name: "inbox", text, raw: `[inbox] ${text}` });
    return parsed?.kind === "inbox" ? parsed.threads?.[0] : undefined;
  };
  const last = notice("lane-b, lane-a (self-declared, unauthenticated)");
  expect(last).toMatchObject({ sender: "lane-a", unverified: true });
  expect(last?.messages).toEqual([{ sender: "lane-a", text: "hi", unverified: true }]);
  const first = notice("lane-a (self-declared, unauthenticated), lane-b");
  expect(first?.sender).toBe("lane-b");
  expect(first?.unverified).toBeUndefined();
});

// A thread acpmux named (`noticeThreads`) keeps its sender: the text's line repeats it for older
// clients, and a name read back from that line never replaces it.
test("a structured notice thread keeps its sender over the text's", () => {
  const text = "New messages from other agents in 1 thread.\n- 1 new in #5 from lane-a: hi (thread pr:5)";
  const parsed = laneNotice({
    name: "inbox",
    text,
    raw: `[inbox] ${text}`,
    noticeThreads: [{ id: "pr:5", sender: "vm-1/lane-a" }],
  });
  if (parsed?.kind !== "inbox") throw new Error("not an inbox notice");
  expect(parsed.threads?.[0]?.sender).toBe("vm-1/lane-a");
  expect(parsed.preview).toBe("vm-1/lane-a");
});
