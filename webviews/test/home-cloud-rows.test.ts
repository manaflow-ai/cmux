// The Channels page's Cloud list and the daemon's home-inbox Cloud rows are two projections of the
// same Cloud inbox entries. Both are held to one corpus (cmux-tui ws_cloud_conversations.rs reads
// the same file through a real daemon), so they cannot drift apart: the page reads the entries
// through its daemon socket exactly as in the app (cloud-session-status, cloud-inbox-list).
import { expect, test } from "bun:test";
import corpus from "../../cmux-tui/crates/cmux-tui/tests/fixtures/home-inbox-cloud-cases.json";
import { CloudHome } from "../src/pages/home-channels/cloudHome";
import { conversation } from "../src/pages/home-channels/daemonHome";
import { conversationName } from "../src/pages/home-channels/model";
import type { DaemonSocket } from "../src/pages/shared/daemonSocket";

type Row = { kind: string; name: string; unread: number; pinned: boolean; muted: boolean };

test("the page's Cloud rows match the shared corpus the daemon's rows follow", async () => {
  const socket = {
    async request(cmd: string): Promise<unknown> {
      if (cmd === "cloud-session-status") return { state: "active", participant: "user_cloudperson0000000" };
      if (cmd === "cloud-inbox-list") return { entries: corpus.cases.map((c) => c.entry) };
      if (cmd === "cloud-inbox-subscribe") return {};
      // Heads are not read here: the corpus is the inbox entries alone.
      throw new Error(`not served: ${cmd}`);
    },
  } as unknown as DaemonSocket;
  const cloud = new CloudHome(socket, conversation, () => {});
  const rows = await cloud.inbox(true);
  for (const c of corpus.cases) {
    const row = rows.find((r) => r.id === c.entry.conversation);
    if (c.row === null) {
      expect(row, c.name).toBeUndefined();
      continue;
    }
    expect(row, c.name).toBeDefined();
    const expected = c.row as Row;
    // The page shows the daemon's channel and group kinds as its "group".
    const kind = expected.kind === "channel" || expected.kind === "group" ? "group" : expected.kind;
    const shown: Record<string, unknown> = {
      kind: row!.kind,
      name: conversationName(row!, "user_local"),
      unread: row!.unread,
      pinned: row!.pinned,
      muted: row!.muted,
    };
    expect(shown, c.name).toEqual({ ...expected, kind } as Record<string, unknown>);
  }
});

test("CloudHome maps conversation presence and localizes participants", async () => {
  const socket = {
    async request(cmd: string): Promise<unknown> {
      if (cmd === "cloud-session-status") return { state: "active", participant: "user_cloudperson0000000" };
      if (cmd === "cloud-inbox-list") return { entries: [] };
      if (cmd === "cloud-inbox-subscribe") return {};
      throw new Error(`not served: ${cmd}`);
    },
  } as unknown as DaemonSocket;
  const cloud = new CloudHome(socket, conversation, () => {});
  await cloud.inbox(true);
  expect(
    cloud.event({
      event: "cloud-conversation-presence",
      conversation: "conv_presence",
      participants: [
        { participant: "user_cloudperson0000000", viewing: true },
        { participant: "tailnet:teammate", viewing: false },
      ],
    }),
  ).toEqual({
    presence: {
      conversation: "conv_presence",
      participants: [
        { participant: "user_local", viewing: true },
        { participant: "tailnet:teammate", viewing: false },
      ],
    },
  });
});

test("a cloud conversation socket that is not live clears its viewers", async () => {
  const socket = {
    async request(cmd: string): Promise<unknown> {
      if (cmd === "cloud-session-status") return { state: "active", participant: "user_cloudperson0000000" };
      if (cmd === "cloud-inbox-list") return { entries: [] };
      if (cmd === "cloud-inbox-subscribe") return {};
      throw new Error(`not served: ${cmd}`);
    },
  } as unknown as DaemonSocket;
  const cloud = new CloudHome(socket, conversation, () => {});
  await cloud.inbox(true);
  const state = (state: string) =>
    cloud.event({ event: "cloud-subscription-state", scope: "conversation", conversation: "conv_presence", state });
  expect(state("connecting")).toEqual({ presence: { conversation: "conv_presence", participants: [] } });
  expect(state("live")).toBeNull();
});
