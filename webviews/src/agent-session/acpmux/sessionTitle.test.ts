// A chat's name in lists (sessionList.ts sessionTitle): a name that reads as an id or a counter
// (`cloud-item-14`, `optchat-sub-6b68ac4a-a26`) yields to the chat's title (Leo 2026-11-02:
// "that's the agents naming them like that").
import { expect, test } from "bun:test";
import { isOpaqueName, sessionTitle } from "./sessionList";

test("names that read as ids or counters are opaque, task names are not", () => {
  for (const name of ["cloud-item-14", "optchat-sub-6b68ac4a-a26", "optchat-chief-h0me", "dispatch-019a3f2e"])
    expect(isOpaqueName(name)).toBe(true);
  for (const name of ["session-info-drag-handles", "drain-cx-b-cloud-ios", "fix-27310-crash", "tests", "claude-sr2"])
    expect(isOpaqueName(name)).toBe(false);
});

test("an opaque name yields to the chat's title, and still beats New chat without one", () => {
  const t = (key: string) => key;
  const titled = { sessionId: "a", name: "cloud-item-14", harness: "codex", title: "Cloud attach retries" };
  expect(sessionTitle(titled, t)).toBe("Cloud attach retries");
  const peer = { ...titled, name: "gcp-codex-lane-12/optchat-sub-6b68ac4a-a26" };
  expect(sessionTitle(peer, t)).toBe("Cloud attach retries");
  expect(sessionTitle({ sessionId: "b", name: "cloud-item-14", harness: "codex" }, t)).toBe("cloud-item-14");
  // A readable name the launcher gave still wins over the title.
  expect(sessionTitle({ ...titled, name: "session-info-drag-handles" }, t)).toBe("session-info-drag-handles");
  // The harness's own default names are unchanged: the title reads.
  expect(sessionTitle({ ...titled, name: "codex-3" }, t)).toBe("Cloud attach retries");
});

// Review of #37653: `lastPrompt` is a whole prompt on one line (acpmux hub/turns.rs, envelope
// already gone on a current daemon), never a preview cut inside a label: words that only start
// like the broker's label title the chat, and a whole label around a message still reads as it.
test("a last prompt that only starts like a relay label titles the chat as written", () => {
  const t = (key: string) => key;
  const chat = { sessionId: "c", name: "codex", harness: "codex" };
  const own = "[message 1234abcd from the parser notes, see below";
  expect(sessionTitle({ ...chat, lastPrompt: own }, t)).toBe(own);
  const relayed =
    '[message 1234abcd from vm-1/lane-a (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message 1234abcd]"] the parser is fixed [end of message 1234abcd]';
  expect(sessionTitle({ ...chat, lastPrompt: relayed }, t)).toBe("the parser is fixed");
});

// cmux#38642 review (F3): acpmux cuts `lastPrompt` to 200 characters and an ellipsis (hub/turns.rs
// `short_text(&line, 200)`), and a relayed head with a long sender runs past that, so the cut ends
// inside the head. The whole-message reader no longer knows it for one and the cut head became the
// chat's title. A prompt cut at that limit reads as a preview: a head cut inside itself holds none of
// the message, and the chat is titled as any chat with no prompt is.
test("a last prompt cut inside a long relay head never titles the chat with the head", () => {
  const t = (key: string) => key;
  const chat = { sessionId: "d", name: "codex", harness: "codex" };
  const sender = `vm-1/${"a-very-long-lane-session-name-".repeat(4)}x`;
  const whole = `[message 1234abcd from ${sender} (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message 1234abcd]"] the parser is fixed [end of message 1234abcd]`;
  const cut = `${whole.slice(0, 200)}…`;
  expect(sessionTitle({ ...chat, lastPrompt: cut }, t)).toBe("sidebar.newChat");
  // A cut prompt past a whole head still titles the chat by the message.
  const short = `[message 1234abcd from vm-1/lane-a (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message 1234abcd]"] ${"the parser is fixed ".repeat(10)}`;
  expect(sessionTitle({ ...chat, lastPrompt: `${short.slice(0, 200)}…` }, t)).toStartWith("the parser is fixed");
  // An opaque name still beats it, as it beats no prompt.
  expect(sessionTitle({ ...chat, name: "cloud-item-14", lastPrompt: cut }, t)).toBe("cloud-item-14");
});

// cmux#38791 review: acpmux's limit counts characters (Rust `chars`), not UTF-16 units. A whole
// prompt under it that ends with its own "…" is not a cut however many units its emoji take, so
// words that only start like a label still title the chat.
test("a whole last prompt of wide characters ending in an ellipsis is not a cut", () => {
  const t = (key: string) => key;
  const chat = { sessionId: "e", name: "codex", harness: "codex" };
  const own = `[message 1234abcd from ${"🙂".repeat(100)}…`;
  expect(own.length).toBeGreaterThan(200);
  expect(sessionTitle({ ...chat, lastPrompt: own }, t)).toBe(own);
});
