import { describe, expect, test } from "bun:test";
import { conversation, message } from "./daemonHome";
import { messageText } from "./model";

describe("a daemon conversation", () => {
  test("carries the others' read cursors for my Read receipts, never mine or an empty one", () => {
    const shown = conversation(
      {
        id: "c1",
        participants: [
          { id: "me", kind: "human", display_name: "Me" },
          { id: "ana", kind: "human", display_name: "Ana" },
          { id: "sam", kind: "human", display_name: "Sam" },
        ],
        last_seq: 4,
        read_cursors: { me: 4, ana: 3, sam: 0 },
      },
      "me",
    );
    expect(shown.readCursors).toEqual({ ana: { seq: 3 } });
    expect(shown.unread).toBe(0);
  });

  test("has no cursors when no one else read", () => {
    expect(conversation({ id: "c2", participants: [], read_cursors: { me: 2 } }, "me").readCursors).toBeUndefined();
  });
});

/** The Channels view keeps reading the owner's question, location and widget parts (Codex review
 * of #40611 at d4d32195, F1: the revert of the React Messages page must not take these with it). */
describe("a daemon message's question, location and widget parts", () => {
  const wire = (part: Record<string, unknown>) =>
    message({ id: "m1", seq: 1, author: "chief", created_at: "2026-11-10T00:00:00Z", parts: [part] });

  test("a question reads as its prompt and choices, not as \"question\"", () => {
    const shown = wire({
      type: "question",
      session: "s1",
      items: [
        {
          id: "q1",
          prompt: "Deploy to production?",
          options: [
            { id: "yes", label: "Yes" },
            { id: "no", label: "No" },
          ],
        },
      ],
    });
    expect(shown.parts[0]?.type).toBe("question");
    expect(messageText(shown)).toBe("Deploy to production?\n1. Yes\n2. No");
  });

  test("a location reads as its label, not as \"location\"", () => {
    const shown = wire({ type: "location", latitude: 37.33, longitude: -122.01, label: "Meet here" });
    expect(shown.parts[0]).toEqual({ type: "location", latitude: 37.33, longitude: -122.01, label: "Meet here" });
    expect(messageText(shown)).toBe("Meet here");
  });

  test("a widget reads as its fallback text, not as \"widget\"", () => {
    const shown = wire({
      type: "widget",
      app: "cmux.weather",
      widget: "cmux.chat.widget/1",
      props: { city: "SF" },
      fallback: "Sunny, 18°C in SF",
    });
    expect(shown.parts[0]?.type).toBe("widget");
    expect(messageText(shown)).toBe("Sunny, 18°C in SF");
  });
});
