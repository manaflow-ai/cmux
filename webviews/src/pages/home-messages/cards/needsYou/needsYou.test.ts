import { describe, expect, it } from "bun:test";
import type { PageClient } from "../../../shared/pageClient";
import { ACTION_RUN, FeedOps } from "../../../feed/types";
import { NEEDS_YOU_ACTION, needsYouFeedClient, parseNeedsYouRoute } from "./FeedNeedsYou";

describe("needs you wire", () => {
  it("reads the Feed route the host names, else nothing shows", () => {
    expect(parseNeedsYouRoute({ route: "#/needs-you" })).toBe("#/needs-you");
    expect(parseNeedsYouRoute({ route: "#/needs-you?style=bar" })).toBe("#/needs-you?style=bar");
    expect(parseNeedsYouRoute(null)).toBeUndefined();
    expect(parseNeedsYouRoute({})).toBeUndefined();
    expect(parseNeedsYouRoute({ route: "#/inbox" })).toBeUndefined(); // only the Needs you view
    expect(parseNeedsYouRoute([{ route: "#/needs-you" }])).toBeUndefined();
  });

  it("sends the Feed page's actions as the host's needsYou.action and its feed ops as they are", async () => {
    const calls: string[] = [];
    const streams: string[] = [];
    const host: PageClient = {
      call: async <R>(op: string) => {
        calls.push(op);
        return {} as R;
      },
      subscribe: async (stream) => {
        streams.push(stream);
        return () => {};
      },
      handle: () => () => {},
    };
    const client = needsYouFeedClient(host);
    await client.call(ACTION_RUN, { action: "feed.openItem", args: {} });
    await client.call(FeedOps.viewRead, { layout: "needs_you" });
    await client.call(FeedOps.intent, {});
    await client.subscribe(FeedOps.viewChanged, () => {});
    expect(calls).toEqual([NEEDS_YOU_ACTION, FeedOps.viewRead, FeedOps.intent]);
    expect(streams).toEqual([FeedOps.viewChanged]);
  });
});
