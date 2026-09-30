// sites.youtube and sites.googleSearch against mock YouTube and Google Search.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("yt");

test("youtube.videoId accepts watch, short, live, embed and youtu.be URLs and bare ids", async () => {
  const ids = await s.value(`["https://www.youtube.com/watch?v=vidDirect01&t=3", "https://youtu.be/vidDirect01?si=x", "https://www.youtube.com/shorts/vidDirect01", "https://m.youtube.com/live/vidDirect01", "https://www.youtube.com/embed/vidDirect01", "vidDirect01"].map((u) => sites.youtube.videoId(u))`);
  assert.deepEqual([...new Set(ids)], ["vidDirect01"]);
  assert.match(await s.error('sites.youtube.videoId("https://vimeo.com/1")'), /expected a YouTube video URL/);
});

test("youtube.search: videoRenderer items anywhere in ytInitialData, deduplicated, limited", async () => {
  const r = await s.value('sites.youtube.search("mock", { limit: 5 })');
  assert.deepEqual(r.map((v) => [v.videoId, v.title]), [["vidDirect01", "Direct Captions"], ["vidPlayer02", "Player Captions"]]);
  assert.deepEqual(r[0], { videoId: "vidDirect01", url: "https://www.youtube.com/watch?v=vidDirect01", title: "Direct Captions", channelName: "Mock Channel", channelUrl: "https://www.youtube.com/@mock", duration: "3:33", views: "12,345 views", published: "5 years ago", thumbnailUrl: "https://i.ytimg.com/x.jpg" });
  assert.equal((await s.value('sites.youtube.search("mock", { limit: 1 })')).length, 1);
});

test("youtube.metadata and captions from the watch page's player response", async () => {
  const m = await s.value('sites.youtube.metadata("https://youtu.be/vidDirect01")');
  assert.deepEqual(m, { videoId: "vidDirect01", url: "https://www.youtube.com/watch?v=vidDirect01", title: "Direct Captions", channelName: "Mock Channel", channelId: "UCmock", channelUrl: "https://www.youtube.com/@mock", durationSeconds: 213, viewCount: 12345, publishDate: "2020-01-02", category: "Education", isLiveContent: false, keywords: ["mock"], description: "A mock video.", thumbnailUrl: "https://i.ytimg.com/l.jpg" });
  assert.deepEqual(await s.value('sites.youtube.captions("vidDirect01")'), [{ lang: "en", name: "English", auto: false }, { lang: "en", name: "English (auto-generated)", auto: true }]);
});

test("youtube.transcript: text, timestamps and segments from the caption track", async () => {
  assert.equal(await s.value('sites.youtube.transcript("vidDirect01")'), "Hello world from Direct Captions");
  assert.equal(await s.value('sites.youtube.transcript("vidDirect01", { timestamps: true })'), "[00:00] Hello world\n[01:01] from Direct Captions");
  assert.deepEqual(await s.value('sites.youtube.transcript("vidDirect01", { format: "segments" })'), [{ start: 0, duration: 1.5, text: "Hello world" }, { start: 61, duration: 2, text: "from Direct Captions" }]);
  assert.match(await s.error('sites.youtube.transcript("vidDirect01", { lang: "fr" })'), /no fr captions; available: en, en \(auto\)/);
});

test("youtube.transcript: a track that needs the player's token is read in a muted background tab, which closes", async () => {
  const before = await s.value("(await tabs.list()).length");
  assert.equal(await s.value('sites.youtube.transcript("https://www.youtube.com/watch?v=vidPlayer02")'), "Hello world from Player Captions");
  assert.ok(env.state.requests.some((r) => /api\/timedtext\?v=vidPlayer02.*pot=player-token.*fmt=json3/.test(r.url)), "fetched the player's caption URL as json3");
  assert.equal(await s.value("(await tabs.list()).length"), before);
});

test("youtube.comments: entity-payload and legacy comment formats, following continuations", async () => {
  const r = await s.value('sites.youtube.comments("vidDirect01", { limit: 10 })');
  assert.deepEqual(r.comments.map((c) => [c.author, c.text, c.likes || null]), [["@alice", "First!", "12"], ["@bob", "Nice video", "3"], ["@carol", "Old format", "7"]]);
  assert.equal(r.comments[0].url, "https://www.youtube.com/watch?v=vidDirect01&lc=c1");
  assert.equal(r.continuation, undefined);
  const two = await s.value('sites.youtube.comments("vidDirect01", { limit: 2 })');
  assert.deepEqual([two.comments.length, two.continuation], [2, "CMT2"]);
  const next = await s.value('sites.youtube.comments("vidDirect01", { continuation: "CMT2" })');
  assert.deepEqual(next.comments.map((c) => c.author), ["@carol"]);
});

test("googleSearch.search: structured results from data-rpos blocks; /url?q= unwrapped; duplicates and Google links dropped", async () => {
  const r = await s.value('sites.googleSearch.search("example")');
  assert.deepEqual(r.map((x) => x.url), ["https://example.com/", "https://www.iana.org/domains/reserved", "https://example.org/q"]);
  assert.deepEqual(r[0], { title: "Example Domain", url: "https://example.com/", sourceName: "Example", publishedAtText: "3 days ago", snippet: "This domain is for use in illustrative examples in documents.", sitelinks: [{ title: "About", url: "https://example.com/about" }, { title: "Help", url: "https://example.com/help" }] });
  assert.equal(r[2].publishedAtText, "Mar 3, 2025");
  assert.equal((await s.value('sites.googleSearch.search("example", { limit: 1 })')).length, 1);
});

test("googleSearch.search: runs one query at a time with a gap, and reports a CAPTCHA without solving it", async () => {
  const before = env.state.requests.length;
  const t0 = Date.now();
  await s.value('Promise.all([sites.googleSearch.search("a"), sites.googleSearch.search("b")])');
  const searches = env.state.requests.slice(before).filter((r) => r.url.startsWith("https://www.google.com/search"));
  assert.equal(searches.length, 2);
  assert.ok(Date.now() - t0 >= 1200, "the second query waited for the gap");
  assert.match(await s.error('sites.googleSearch.search("trigger captcha")'), /CAPTCHA.*does not solve CAPTCHAs/);
  assert.match(await s.error('sites.googleSearch.search("x", { time: "decade" })'), /time: expected day, week, month or year/);
});
