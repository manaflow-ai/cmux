// Review of #37571 at 1eac536b: the author's picture reaches the host after the read it belongs to,
// so the next answer carries the same `fetchedAt`; the store kept the answer without it.
import { expect, test } from "bun:test";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import {
  askPullRequest,
  pullRequestAnswer,
  resetPullRequestStore,
} from "../src/agent-session/acpmux/chips/pullRequestStore";

const URL = "https://github.com/manaflow-ai/cmux/pull/1";
const pullRequest = { url: URL, number: 1, title: "t", state: "open", checks: { state: "", passed: 0, total: 0 } };

test("an avatar that arrives under the same fetchedAt replaces the answer without it", async () => {
  resetPullRequestStore();
  let avatar: string | undefined;
  setChipHost(async () => ({ pullRequest: { ...pullRequest, authorAvatar: avatar }, fetchedAt: 100, reading: false }));
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  askPullRequest(URL);
  await settle();
  expect(pullRequestAnswer(URL)?.pullRequest?.authorAvatar).toBeUndefined();
  avatar = "data:image/png;base64,AAAA";
  askPullRequest(URL);
  await settle();
  expect(pullRequestAnswer(URL)?.pullRequest?.authorAvatar).toBe("data:image/png;base64,AAAA");
  setChipHost(undefined);
});
