// l10n-allow-file: test fixture prompts, not shipped UI.
// ask-17e4ae3662 (Austin): "when we do a “transition” to a cloud chat it likes blinks out and then changes the chat…
// sometimes there is an error and the chat just goes blank and stuff or loads forever".
import { expect, test } from "bun:test";
import {
  CLOUD_CHAT_NOT_SHOWN,
  CLOUD_CHAT_SHOW_MS,
  cloudChatNotShown,
  cloudChatShown,
  cloudStartBegun,
  cloudStartEnded,
  cloudStartOpened,
  cloudStartStalled,
  cloudStartWayOn,
  watchCloudChatShow,
  watchCloudStartStall,
} from "../src/agent-session/acpmux/cloudStartProgress";
import { translate } from "../src/agent-session/acpmux/i18n";

const begun = () => cloudStartBegun("k-1", "fix the build", "/Users/me/src/paint/");
const manual = () => {
  const armed: Array<{ run: () => void; ms: number }> = [];
  const schedule = (run: () => void, ms: number) => {
    armed.push({ run, ms });
    return () => undefined;
  };
  return { armed, schedule };
};

test("an ok answer keeps the card (the message, opening) instead of clearing it", () => {
  const opened = cloudStartOpened({ ...begun(), stalled: true }, "k-1", "local-empty", 1_000);
  expect(opened).toMatchObject({ key: "k-1", task: "fix the build", state: "starting", step: "opening" });
  expect(opened?.opened).toEqual({ replaced: "local-empty", at: 1_000 });
  expect(opened?.stalled).toBeUndefined();
  // Another start's answer changes nothing; none shown stays none.
  expect(cloudStartOpened(begun(), "k-2", undefined)).toEqual(begun());
  expect(cloudStartOpened(undefined, "k-1", undefined)).toBeUndefined();
  // The ok without a handover (other callers) still clears.
  expect(cloudStartEnded(begun(), "k-1", { ok: true })).toBeUndefined();
});

test("the card holds until the Cloud chat draws a row, never on the replaced empty chat", () => {
  const opened = cloudStartOpened(begun(), "k-1", "local-empty", 0);
  // Rehomed page: no session yet, then the Cloud session with no rows: neither is the Cloud chat drawn.
  expect(cloudChatShown({ rows: [] }, opened)).toBe(false);
  expect(cloudChatShown({ sessionId: "local-empty", rows: [{}] }, opened)).toBe(false);
  expect(cloudChatShown({ sessionId: "cloud-1", rows: [] }, opened)).toBe(false);
  expect(cloudChatShown({ sessionId: "cloud-1", rows: [{}] }, opened)).toBe(true);
  // A start not answered yet is never "shown" by rows.
  expect(cloudChatShown({ sessionId: "cloud-1", rows: [{}] }, begun())).toBe(false);
  expect(cloudChatShown({ sessionId: "cloud-1", rows: [{}] }, undefined)).toBe(false);
});

test("an opened start that never draws becomes a named failure with Retry, not a forever load", () => {
  const opened = cloudStartOpened(begun(), "k-1", undefined, 10_000);
  const { armed, schedule } = manual();
  const fired: string[] = [];
  watchCloudChatShow(opened, (key) => fired.push(key), CLOUD_CHAT_SHOW_MS, schedule, 25_000);
  expect(armed).toHaveLength(1);
  expect(armed[0]?.ms).toBe(10_000 + CLOUD_CHAT_SHOW_MS - 25_000);
  armed[0]?.run();
  expect(fired).toEqual(["k-1"]);

  const failed = cloudChatNotShown(opened, "k-1");
  expect(failed).toMatchObject({
    state: "failed",
    code: CLOUD_CHAT_NOT_SHOWN,
    message: translate("cloudStart.chatNotShown"),
  });
  expect(failed?.message).toBeTruthy();
  // Retry reloads (attaches the chat again) rather than starting a second billed machine.
  expect(cloudStartWayOn(failed!)).toEqual(["reload", "dismiss"]);
  // Late for another start, a start not opened, or one already failed: unchanged.
  expect(cloudChatNotShown(opened, "k-2")).toBe(opened);
  expect(cloudChatNotShown(begun(), "k-1")).toEqual(begun());
  expect(cloudChatNotShown(failed, "k-1")).toBe(failed);
  // No timer for a start that is not opened or already failed.
  const quiet = manual();
  watchCloudChatShow(begun(), () => undefined, CLOUD_CHAT_SHOW_MS, quiet.schedule, 0);
  watchCloudChatShow(failed, () => undefined, CLOUD_CHAT_SHOW_MS, quiet.schedule, 0);
  expect(quiet.armed).toHaveLength(0);
});

test("the host-silence stall watcher leaves an opened start to the show timer", () => {
  const opened = cloudStartOpened(begun(), "k-1", undefined, 0);
  const { armed, schedule } = manual();
  watchCloudStartStall(opened, () => undefined, 1_000, schedule, 0);
  expect(armed).toHaveLength(0);
  expect(cloudStartStalled(opened, "k-1")).toBe(opened);
});
