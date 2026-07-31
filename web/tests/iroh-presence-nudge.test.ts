import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import {
  IROH_PRESENCE_NUDGE_KIND,
  IROH_PRESENCE_NUDGE_MAX_EVENTS,
  irohNudgeEventKey,
  makeIrohPresenceNudge,
  type IrohBindingNudgeEvent,
} from "../services/iroh/presenceNudge";

const EVENT: IrohBindingNudgeEvent = {
  userId: "user-owner",
  deviceUuid: "11111111-2222-4333-8444-555555555555",
  tag: "wsid",
};

type RecordedPost = {
  readonly url: string;
  readonly secret: string | null;
  readonly body: Record<string, unknown>;
};

function recordingFetch(record: RecordedPost[], respond: () => Response | Promise<Response>) {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    record.push({
      url: String(input),
      secret: new Headers(init?.headers).get("x-cmux-nudge-secret"),
      body: JSON.parse(String(init?.body)) as Record<string, unknown>,
    });
    return respond();
  }) as typeof fetch;
}

describe("iroh presence nudge client", () => {
  test("posts one server nudge per candidate team plus the solo fallback", async () => {
    const posts: RecordedPost[] = [];
    const nudge = makeIrohPresenceNudge({
      baseUrl: "https://presence.example.test/",
      secret: "0123456789abcdef",
      fetchImpl: recordingFetch(posts, () => new Response("{}", { status: 200 })),
      lookupCandidateTeamIds: async (events) => new Map([
        [irohNudgeEventKey(events[0]!), ["team-1", "user-owner"]],
      ]),
    });

    await Effect.runPromise(nudge.bindingChanged([EVENT]));

    // "user-owner" appears both as a registry candidate and as the solo
    // fallback; it must be posted once, so exactly two DO targets are hit.
    expect(posts).toHaveLength(2);
    expect(new Set(posts.map((post) => post.body.teamId))).toEqual(new Set(["team-1", "user-owner"]));
    for (const post of posts) {
      expect(post.url).toBe("https://presence.example.test/v1/presence/nudge");
      expect(post.secret).toBe("0123456789abcdef");
      expect(post.body).toMatchObject({
        deviceId: EVENT.deviceUuid,
        tag: EVENT.tag,
        kind: IROH_PRESENCE_NUDGE_KIND,
        userId: EVENT.userId,
      });
    }
  });

  test("is a no-op without configuration", async () => {
    const posts: RecordedPost[] = [];
    const fetchImpl = recordingFetch(posts, () => new Response("{}", { status: 200 }));
    const noUrl = makeIrohPresenceNudge({ secret: "0123456789abcdef", fetchImpl });
    const noSecret = makeIrohPresenceNudge({ baseUrl: "https://presence.example.test", fetchImpl });

    await Effect.runPromise(noUrl.bindingChanged([EVENT]));
    await Effect.runPromise(noSecret.bindingChanged([EVENT]));

    expect(posts).toEqual([]);
  });

  test("never fails on rejected fetches, non-2xx responses, or lookup errors", async () => {
    const rejecting = makeIrohPresenceNudge({
      baseUrl: "https://presence.example.test",
      secret: "0123456789abcdef",
      fetchImpl: (() => Promise.reject(new Error("connect timeout"))) as typeof fetch,
      lookupCandidateTeamIds: async () => {
        throw new Error("database unavailable");
      },
    });
    await Effect.runPromise(rejecting.bindingChanged([EVENT]));

    const failing = makeIrohPresenceNudge({
      baseUrl: "https://presence.example.test",
      secret: "0123456789abcdef",
      fetchImpl: (async () => new Response("{}", { status: 500 })) as typeof fetch,
    });
    await Effect.runPromise(failing.bindingChanged([EVENT]));
  });

  test("bounds the number of events posted per call", async () => {
    const posts: RecordedPost[] = [];
    const nudge = makeIrohPresenceNudge({
      baseUrl: "https://presence.example.test",
      secret: "0123456789abcdef",
      fetchImpl: recordingFetch(posts, () => new Response("{}", { status: 200 })),
      lookupCandidateTeamIds: async () => new Map(),
    });
    const events = Array.from({ length: IROH_PRESENCE_NUDGE_MAX_EVENTS + 10 }, (_, index): IrohBindingNudgeEvent => ({
      userId: "user-owner",
      deviceUuid: `11111111-2222-4333-8444-${String(index).padStart(12, "0")}`,
      tag: "wsid",
    }));

    await Effect.runPromise(nudge.bindingChanged(events));

    expect(posts).toHaveLength(IROH_PRESENCE_NUDGE_MAX_EVENTS);
  });
});
