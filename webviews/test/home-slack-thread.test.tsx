import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { message } from "../src/pages/home-channels/daemonHome";
import { SlackThreadLabel } from "../src/pages/home-channels/SlackThreadLabel";
import { slackThreadSource } from "../src/pages/home-channels/slackThread";
import { threadObject } from "../src/pages/home-channels/threads";

const metadata = {
  source: "slack",
  channelName: "release",
  channelId: "C01234567",
  slackTeamId: "T01234567",
  threadTs: "1789644309.000000",
  permalink: "https://example.slack.com/archives/C01234567/p1789644309000000",
  chief: "agent_chief",
  ownerUserId: "user_owner",
};

test("the hosted root metadata reaches a linked Slack label through the production projection", () => {
  const root = message({
    id: "msg_root",
    conversation: "conv_chief",
    seq: 1,
    author: "slack:T01234567:U01234567",
    created_at: "2026-11-03T00:00:00Z",
    parts: [{ type: "text", text: "What is left on the release?" }],
    thread: { ...metadata, title: "Release checklist" },
  });
  const thread = threadObject(root, undefined, undefined);
  expect(thread.title).toBe("Release checklist");
  const html = renderToStaticMarkup(<SlackThreadLabel source={thread.slack} />);
  expect(html).toContain("Slack · #release");
  expect(html).toContain(`href="${metadata.permalink}"`);
  expect(html).toContain('rel="noopener noreferrer"');
});

test("ordinary threads have no Slack label", () => {
  for (const raw of [undefined, {}, { source: "web", channelName: "release" }, { source: "slack" }]) {
    expect(renderToStaticMarkup(<SlackThreadLabel source={slackThreadSource(raw)} />)).toBe("");
  }
});

test("a channel gets one hash and its user content is escaped", () => {
  const source = slackThreadSource({ ...metadata, channelName: "#<release>" });
  const html = renderToStaticMarkup(<SlackThreadLabel source={source} />);
  expect(html).toContain("Slack · #&lt;release&gt;");
  expect(html).not.toContain("##");
});

test("malformed and non-Slack permalinks never create an actionable link", () => {
  for (const permalink of [
    "javascript:alert(1)",
    "http://example.slack.com/archives/C01234567/p1789644309000000",
    "https://slack.com.evil.test/archives/C01234567/p1789644309000000",
    "https://evilslack.com/archives/C01234567/p1789644309000000",
    "https://user:password@example.slack.com/archives/C01234567/p1789644309000000",
    "/relative",
  ]) {
    const source = slackThreadSource({ ...metadata, permalink });
    const html = renderToStaticMarkup(<SlackThreadLabel source={source} />);
    expect(html).toContain("Slack · #release");
    expect(html).not.toContain("href=");
  }
});
