// l10n-allow-file: test fixtures.
// A sub-session's card showed its prompt's opening words twice: once as its `doing` line (acpmux names a
// fresh session from its prompt) and again as the start of the prompt preview right under it. Leo,
// 2026-10-29: "this doubling up is kinda weird? first line then whatever goes next". The line is left
// out when it only repeats the prompt's start; any other line (a real step, a wait, an error) stays.
import { expect, test } from "bun:test";
import { repeatsPrompt } from "../src/agent-session/acpmux/conversation/SubsessionCallCard";

const prompt =
  "You are ios-remote, the area owner for cmux's iOS app and the remote/mobile client (the cmux-remote code, including its Iroh transport), in example/cmux.";

test("a line that is the prompt's opening, cut mid-word with an ellipsis, repeats it", () => {
  expect(
    repeatsPrompt(
      "You are ios-remote, the area owner for cmux's iOS app and the remote/mobile client (the cmux-remote code, includi…",
      prompt,
    ),
  ).toBe(true);
  expect(repeatsPrompt("You are ios-remote, the area owner...", prompt)).toBe(true);
  expect(repeatsPrompt("you  are   IOS-remote,", prompt)).toBe(true);
});

test("a line that says what the session does now is not a repeat", () => {
  expect(repeatsPrompt("Read src/net/RetryBanner.tsx", prompt)).toBe(false);
  expect(repeatsPrompt("Working on: You are ios-remote…", prompt)).toBe(false);
  expect(repeatsPrompt("You are net-retries, a lane", prompt)).toBe(false);
  expect(repeatsPrompt("", prompt)).toBe(false);
});
