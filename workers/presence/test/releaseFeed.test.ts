import { describe, expect, it } from "bun:test";
import {
  POKE_COALESCE_MS,
  RELEASE_FEEDS,
  MAX_APPCAST_BYTES,
  ReleaseFeedCore,
  fetchAppcast,
  parseNewestRelease,
  parseReleaseFeedId,
  type ReleaseFeedHost,
  type ReleaseState,
} from "../src/releaseFeed";
import { pokeAllReleaseFeeds, releaseFeedRoute, type ReleaseFeedNamespace } from "../src/releaseFeedRoute";

function item(build: string, extra = ""): string {
  return `<item>
    <title>1.0.0-nightly.${build}</title>
    <sparkle:version>${build}</sparkle:version>
    <sparkle:shortVersionString>1.0.0-nightly.${build}</sparkle:shortVersionString>
    <enclosure url="https://files-next.cmux.com/x/${build}.dmg" length="1" sparkle:edSignature="sig"/>
    ${extra}
  </item>`;
}

function appcast(...items: string[]): string {
  return `<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>${items.join("")}</channel></rss>`;
}

class FakeHost implements ReleaseFeedHost {
  clock = 1_000_000;
  feed = appcast(item("100"));
  fetched: string[] = [];
  stored: ReleaseState | null = null;
  frames: string[] = [];
  alarmAt: number | null = null;
  readAt = 0;

  now() { return this.clock; }
  async fetchAppcast(url: string) { this.fetched.push(url); return this.feed; }
  async load() { return this.stored; }
  async save(state: ReleaseState) { this.stored = state; }
  async loadReadAt() { return this.readAt; }
  async saveReadAt(at: number) { this.readAt = at; }
  broadcast(frame: string) { this.frames.push(frame); }
  async getAlarm() { return this.alarmAt; }
  async setAlarm(at: number) { this.alarmAt = at; }
}

describe("appcast parse", () => {
  it("picks the highest sparkle:version, whatever the item order", () => {
    expect(parseNewestRelease(appcast(item("4037632091801"), item("4038033920301"), item("4037856525201"))))
      .toEqual({ build: 4038033920301, version: "1.0.0-nightly.4038033920301" });
  });

  it("ignores malformed items and delta enclosures", () => {
    const deltas = `<sparkle:deltas><enclosure url="d" sparkle:deltaFrom="99" sparkle:version="999999"/></sparkle:deltas>`;
    const xml = appcast(
      item("200", deltas),
      "<item><title>no build</title></item>",
      item("9999abc"),
      item("1.2.3"),
      `<item><sparkle:version>500</sparkle:version><sparkle:version>600</sparkle:version></item>`,
      `<item><sparkle:version>700</sparkle:version><enclosure url="u" sparkle:version="800"/></item>`,
      item("99999999999999999999"),
      "<item><sparkle:version>",
    );
    expect(parseNewestRelease(xml)).toEqual({ build: 200, version: "1.0.0-nightly.200" });
  });

  it("reads the enclosure attribute form and returns null with no usable item", () => {
    expect(parseNewestRelease(appcast(`<item><enclosure url="u" sparkle:version="42" sparkle:shortVersionString="1.0.42"/></item>`)))
      .toEqual({ build: 42, version: "1.0.42" });
    expect(parseNewestRelease(appcast("<item><title>x</title></item>"))).toBeNull();
    expect(parseNewestRelease("not xml")).toBeNull();
  });

  it("never reads an item or a version from comments or CDATA", () => {
    const xml = appcast(
      item("300", `<description><![CDATA[<item><sparkle:version>999</sparkle:version></item>]]></description>`),
      "<!-- <item><sparkle:version>998</sparkle:version></item> -->",
    );
    expect(parseNewestRelease(xml)).toEqual({ build: 300, version: "1.0.0-nightly.300" });
  });

  it("drops a short version that is not a plain version string", () => {
    const xml = appcast(`<item><sparkle:version>7</sparkle:version><sparkle:shortVersionString>"><script></sparkle:shortVersionString></item>`);
    expect(parseNewestRelease(xml)).toEqual({ build: 7, version: "" });
  });
});

describe("appcast fetch", () => {
  it("returns the body only for a 2xx answer within the size cap", async () => {
    const answer = (response: Response) => (async () => response) as unknown as typeof fetch;
    expect(await fetchAppcast("https://x", answer(new Response("<rss/>")))).toBe("<rss/>");
    expect(await fetchAppcast("https://x", answer(new Response(null, { status: 302, headers: { location: "https://evil.test" } })))).toBeNull();
    expect(await fetchAppcast("https://x", answer(new Response("gone", { status: 404 })))).toBeNull();
    expect(await fetchAppcast("https://x", answer(new Response("x".repeat(MAX_APPCAST_BYTES + 1))))).toBeNull();
    // The cap counts bytes, not UTF-16 code units: 2-byte characters past the cap are refused.
    expect(await fetchAppcast("https://x", answer(new Response("é".repeat(MAX_APPCAST_BYTES / 2 + 1))))).toBeNull();
    expect(await fetchAppcast("https://x", answer(new Response("é".repeat(10))))).toBe("é".repeat(10));
    expect(await fetchAppcast("https://x", (async () => { throw new Error("offline"); }) as unknown as typeof fetch)).toBeNull();
  });
});

describe("release feed pokes", () => {
  it("raises the build on a poke and broadcasts it", async () => {
    const host = new FakeHost();
    const core = new ReleaseFeedCore("nightly-next", host);
    expect(await core.poke()).toEqual({ build: 100 });
    expect(host.fetched).toHaveLength(1);
    expect(host.fetched[0]).toBe(`${RELEASE_FEEDS["nightly-next"]}?t=${host.clock}`);
    expect(host.frames.map((f) => JSON.parse(f))).toEqual([{
      type: "release", feed: "nightly-next", build: 100, version: "1.0.0-nightly.100",
      at: new Date(host.clock).toISOString(),
    }]);

    host.clock += POKE_COALESCE_MS;
    host.feed = appcast(item("100"), item("101"));
    expect(await core.poke()).toEqual({ build: 101 });
    expect(host.frames).toHaveLength(2);
    expect(JSON.parse(host.frames[1]!).build).toBe(101);
  });

  it("does not broadcast an equal or lower build", async () => {
    const host = new FakeHost();
    const core = new ReleaseFeedCore("tip", host);
    await core.poke();
    const firstSeen = host.stored;

    host.clock += POKE_COALESCE_MS;
    expect(await core.poke()).toEqual({ build: 100 });
    host.clock += POKE_COALESCE_MS;
    host.feed = appcast(item("99"));
    expect(await core.poke()).toEqual({ build: 100 });

    expect(host.fetched).toHaveLength(3);
    expect(host.frames).toHaveLength(1);
    expect(host.stored).toEqual(firstSeen);
  });

  it("keeps the stored build when the feed is unreadable", async () => {
    const host = new FakeHost();
    const core = new ReleaseFeedCore("tip", host);
    await core.poke();
    host.clock += POKE_COALESCE_MS;
    host.feed = "<html>502</html>";
    expect(await core.poke()).toEqual({ build: 100 });
    expect(host.frames).toHaveLength(1);
  });

  it("coalesces pokes inside the window into one deferred read", async () => {
    const host = new FakeHost();
    const core = new ReleaseFeedCore("nightly-next", host);
    await core.poke();
    const firstRead = host.clock;

    host.feed = appcast(item("101"));
    for (const step of [1_000, 2_000, 3_000]) {
      host.clock = firstRead + step;
      expect(await core.poke()).toEqual({ build: 100 });
    }
    expect(host.fetched).toHaveLength(1);
    expect(host.alarmAt).toBe(firstRead + POKE_COALESCE_MS);

    host.clock = firstRead + POKE_COALESCE_MS;
    host.alarmAt = null; // the runtime clears a fired alarm
    await core.alarm();
    expect(host.fetched).toHaveLength(2);
    expect(host.alarmAt).toBeNull();
    expect(JSON.parse(host.frames.at(-1)!).build).toBe(101);
  });

  it("keeps the window across an eviction (a fresh core on the same storage)", async () => {
    const host = new FakeHost();
    await new ReleaseFeedCore("tip", host).poke();
    host.clock += 1_000;
    await new ReleaseFeedCore("tip", host).poke();
    expect(host.fetched).toHaveLength(1);
    expect(host.alarmAt).not.toBeNull();
  });

  it("replaces a stale alarm so the last poke is never dropped", async () => {
    const host = new FakeHost();
    const core = new ReleaseFeedCore("tip", host);
    const t0 = host.clock;
    await core.poke();                                  // read at t0
    host.clock = t0 + 1_000; await core.poke();         // arms t0+10s
    host.clock = t0 + POKE_COALESCE_MS; await core.poke(); // reads before that alarm runs
    host.feed = appcast(item("101"));
    host.clock = t0 + POKE_COALESCE_MS + 1_000; await core.poke(); // new build, inside the new window
    expect(host.alarmAt).toBe(t0 + 2 * POKE_COALESCE_MS);
    host.clock = host.alarmAt!; host.alarmAt = null;
    await core.alarm();
    expect(host.stored?.build).toBe(101);
  });

  it("skips the alarm read when a poke already read at its due time", async () => {
    const host = new FakeHost();
    const core = new ReleaseFeedCore("tip", host);
    await core.poke();
    host.clock += 1_000;
    await core.poke();
    host.clock = host.alarmAt!;
    await core.poke(); // due-time poke reads at once
    host.alarmAt = null;
    await core.alarm();
    expect(host.fetched).toHaveLength(2);
  });
});

describe("release feed sockets", () => {
  it("gives a new socket the current state, reading the feed once if none is stored", async () => {
    const host = new FakeHost();
    const core = new ReleaseFeedCore("nightly-next", host);
    const first = JSON.parse((await core.current())!);
    expect(first).toMatchObject({ type: "release", feed: "nightly-next", build: 100 });

    host.feed = appcast(item("200"));
    host.clock += POKE_COALESCE_MS;
    expect(JSON.parse((await core.current())!)).toEqual(first);
    expect(host.fetched).toHaveLength(1);
  });

  it("keeps latestFrame at the newest broadcast for a joining socket", async () => {
    const host = new FakeHost();
    const core = new ReleaseFeedCore("tip", host);
    await core.current();
    host.clock += POKE_COALESCE_MS;
    host.feed = appcast(item("150"));
    await core.poke();
    expect(core.latestFrame).toBe(host.frames.at(-1)!);
    expect(JSON.parse(core.latestFrame!).build).toBe(150);
  });

  it("has no frame while the feed has never been readable", async () => {
    const host = new FakeHost();
    host.feed = "";
    expect(await new ReleaseFeedCore("tip", host).current()).toBeNull();
  });
});

describe("release feed routes", () => {
  function fakeNamespace() {
    const calls: { name: string; path: string; feed: string | null; method: string; upgrade: string | null }[] = [];
    let lastName = "";
    const namespace: ReleaseFeedNamespace = {
      idFromName(name: string) { lastName = name; return name; },
      get() {
        const name = lastName;
        return {
          async fetch(request: Request) {
            calls.push({
              name,
              path: new URL(request.url).pathname,
              feed: request.headers.get("x-release-feed"),
              method: request.method,
              upgrade: request.headers.get("upgrade"),
            });
            return Response.json({ build: 1 }, { status: 202 });
          },
        };
      },
    };
    return { calls, env: { RELEASE_FEED: namespace } };
  }

  it("returns 404 for an unknown or missing feed without touching an object", async () => {
    const { calls, env } = fakeNamespace();
    for (const query of ["?feed=stable", "?feed=__proto__", "?feed=https://evil.test/a.xml", ""]) {
      const response = await releaseFeedRoute(new Request(`https://presence.cmux.dev/releases/v1/poke${query}`, { method: "POST" }), env);
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ error: "unknown_feed" });
    }
    expect(calls).toHaveLength(0);
    expect(parseReleaseFeedId("constructor")).toBeNull();
  });

  it("forwards only the validated feed id to that feed's object", async () => {
    const { calls, env } = fakeNamespace();
    const poke = await releaseFeedRoute(new Request("https://presence.cmux.dev/releases/v1/poke?feed=tip", {
      method: "POST", headers: { "x-release-feed": "nightly-next", authorization: "Bearer x" }, body: "ignored",
    }), env);
    expect(poke.status).toBe(202);
    expect(calls).toEqual([{ name: "tip", path: "/poke", feed: "tip", method: "POST", upgrade: null }]);
  });

  it("serves the bare nightly-next appcast as nightly-next-legacy", async () => {
    expect(RELEASE_FEEDS["nightly-next-legacy"]).toBe("https://files-next.cmux.com/nightly-next/appcast-arm64.xml");
    expect(parseReleaseFeedId("nightly-next-legacy")).toBe("nightly-next-legacy");
    const { calls, env } = fakeNamespace();
    const poke = await releaseFeedRoute(new Request("https://presence.cmux.dev/releases/v1/poke?feed=nightly-next-legacy", { method: "POST" }), env);
    expect(poke.status).toBe(202);
    expect(calls).toEqual([{ name: "nightly-next-legacy", path: "/poke", feed: "nightly-next-legacy", method: "POST", upgrade: null }]);
  });

  it("checks methods and the WebSocket upgrade", async () => {
    const { calls, env } = fakeNamespace();
    const base = "https://presence.cmux.dev/releases/v1";
    expect((await releaseFeedRoute(new Request(`${base}/poke?feed=tip`), env)).status).toBe(405);
    expect((await releaseFeedRoute(new Request(`${base}/socket?feed=tip`), env)).status).toBe(400);
    expect((await releaseFeedRoute(new Request(`${base}/nope?feed=tip`), env)).status).toBe(404);
    await releaseFeedRoute(new Request(`${base}/socket?feed=nightly-next`, { headers: { upgrade: "websocket" } }), env);
    expect(calls).toEqual([{ name: "nightly-next", path: "/socket", feed: "nightly-next", method: "GET", upgrade: "websocket" }]);
  });

  it("pokes every feed from the cron", async () => {
    const { calls, env } = fakeNamespace();
    await pokeAllReleaseFeeds(env);
    expect(calls.map((c) => c.name).sort()).toEqual(Object.keys(RELEASE_FEEDS).sort());
    expect(calls.every((c) => c.path === "/poke" && c.method === "POST")).toBe(true);
  });
});
