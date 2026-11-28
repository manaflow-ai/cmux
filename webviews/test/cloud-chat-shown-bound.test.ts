// l10n-allow-file: test fixture prompts, not shipped UI.
// ask-17e4ae3662 (Austin): "sometimes there is an error and the chat just goes blank and stuff or loads forever".
import { expect, test } from "bun:test";
import {
  CLOUD_CHAT_SHOW_MS,
  cloudChatNotShown,
  cloudStartOpened,
  cloudStartWaitsForFirstPage,
  watchCloudChatShow,
} from "../src/agent-session/acpmux/cloudStartOpened";
import { CLOUD_CHAT_NOT_SHOWN, cloudStartBegun, cloudStartWayOn } from "../src/agent-session/acpmux/cloudStartProgress";
import { translate } from "../src/agent-session/acpmux/i18n";

const manual = () => {
  const armed: Array<{ run: () => void; ms: number }> = [];
  const schedule = (run: () => void, ms: number) => {
    armed.push({ run, ms });
    return () => undefined;
  };
  return { armed, schedule };
};
const opened = (at = 1_000) =>
  cloudStartOpened(cloudStartBegun("k-1", "fix the build", "/Users/me/src/paint/"), "k-1", at);

test("an opened start arms the show timer a minute after the open", () => {
  const { armed, schedule } = manual();
  const fired: string[] = [];
  watchCloudChatShow(opened(1_000), (key) => fired.push(key), CLOUD_CHAT_SHOW_MS, schedule, 21_000);
  expect(armed.map((a) => a.ms)).toEqual([CLOUD_CHAT_SHOW_MS - 20_000]);
  armed[0]?.run();
  expect(fired).toEqual(["k-1"]);
});

test("a start not yet opened arms no show timer", () => {
  const { armed, schedule } = manual();
  watchCloudChatShow(cloudStartBegun("k-1", "fix the build", undefined), () => undefined, CLOUD_CHAT_SHOW_MS, schedule);
  expect(armed).toEqual([]);
});

test("the timeout fails the card by name, with a reload and Not now, and the card still shows", () => {
  const failed = cloudChatNotShown(opened(), "k-1");
  expect(failed?.state).toBe("failed");
  expect(failed?.code).toBe(CLOUD_CHAT_NOT_SHOWN);
  expect(failed?.message).toBe(translate("cloudStart.chatNotShown"));
  expect(failed?.task).toBe("fix the build");
  expect(failed && cloudStartWayOn(failed)).toEqual(["reload", "dismiss"]);
  expect(cloudStartWaitsForFirstPage(failed, { sessionId: "cloud-1", rows: [] })).toBe(true);
  expect(cloudStartWaitsForFirstPage(failed, { sessionId: "cloud-1", rows: [{ kind: "user", at: 2 }] })).toBe(false);
});

test("the timeout leaves another start, or one that already ended, alone", () => {
  const start = opened();
  expect(cloudChatNotShown(start, "k-2")).toBe(start);
  expect(cloudChatNotShown(undefined, "k-1")).toBeUndefined();
  const failed = cloudChatNotShown(start, "k-1");
  expect(cloudChatNotShown(failed, "k-1")).toBe(failed);
});
