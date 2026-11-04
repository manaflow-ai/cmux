// Chief cards (https://github.com/manaflow-ai/cmux/issues/25830): the page reads an owner's `card`
// parts (browser, sign_in, next_steps) into its own model, keeps the screenshot as an attachment it
// fetches like any other, shows a newer kind as plain text, and copies a card as its text fallback.
import { expect, test } from "bun:test";
import { message } from "../src/pages/home-channels/daemonHome";
import { messageText } from "../src/pages/home-channels/model";

const raw = (parts: unknown[]) => ({
  id: "msg_1",
  conversation: "conv_1",
  seq: 1,
  author: "agent_chief",
  created_at: "2026-10-26T12:00:00Z",
  client_msg_id: "c1",
  parts,
  reactions: [],
});

test("card parts project to the page model and copy as their text fallback", () => {
  const hash = "e".repeat(64);
  const read = message(
    raw([
      {
        type: "card",
        kind: "browser",
        surface: "computer",
        step: "Opening Mail",
        live: true,
        target: "machine:m1",
        url: "https://mail.example.com/",
        image: { hash, mime_type: "image/png", byte_count: 1000, width: 1280, height: 800 },
      },
      { type: "card", kind: "sign_in", site: "linkedin.com" },
      { type: "card", kind: "next_steps", choices: ["Retry", "Stop"] },
      { type: "card", kind: "map", step: "x" },
    ]),
  );
  expect(read.parts).toEqual([
    {
      type: "card",
      kind: "browser",
      surface: "computer",
      step: "Opening Mail",
      live: true,
      target: "machine:m1",
      url: "https://mail.example.com/",
      image: {
        type: "attachment",
        hash,
        name: "browser-card.png",
        mimeType: "image/png",
        byteCount: 1000,
        width: 1280,
        height: 800,
      },
    },
    { type: "card", kind: "sign_in", site: "linkedin.com" },
    { type: "card", kind: "next_steps", choices: ["Retry", "Stop"] },
    { type: "other", text: "map" },
  ]);
  expect(messageText(read)).toBe("Computer: Opening Mail\nSecure Store: sign in to linkedin.com\n→ Retry\n→ Stop\nmap");
});
