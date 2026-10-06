// sites.linkedin and sites.x against mock pages and LinkedIn's Voyager API.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";
import { SECRETS } from "./mock-sites.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("social");

test("linkedin.me and profile use the Voyager API with the page's CSRF value, which never returns", async () => {
  assert.deepEqual(await s.value("sites.linkedin.me()"), { id: 424242, publicIdentifier: "ada-lovelace", firstName: "Ada", lastName: "Lovelace", headline: "Analyst", url: "https://www.linkedin.com/in/ada-lovelace/" });
  assert.deepEqual(await s.value('sites.linkedin.profile("https://www.linkedin.com/in/grace-hopper/")'), { publicIdentifier: "grace-hopper", firstName: "Grace", lastName: "Hopper", headline: "Rear Admiral", location: "Arlington, Virginia", url: "https://www.linkedin.com/in/grace-hopper/" });
  const scope = Object.keys(s.repl.scope).map((k) => { try { return JSON.stringify(s.repl.scope[k]); } catch { return ""; } }).join("\n");
  assert.ok(!scope.includes(SECRETS.linkedinJsession));
});

test("linkedin.search and feed read result cards", async () => {
  const people = await s.value('sites.linkedin.search("admiral")');
  assert.deepEqual(people.map((p) => [p.name, p.url, p.summary[0]]), [["Grace Hopper", "https://www.linkedin.com/in/grace-hopper/", "Rear Admiral"], ["Alan Turing", "https://www.linkedin.com/in/alan-t/", "Mathematician"]]);
  const feed = await s.value("sites.linkedin.feed({ limit: 2 })");
  assert.deepEqual(feed.map((f) => [f.id, f.author, f.authorUrl, f.text]), [["ck-post-1", "Grace Hopper", "https://www.linkedin.com/in/grace-hopper/", "Compilers are fun."], ["ck-post-2", "Alan Turing", "https://www.linkedin.com/in/alan-t/", "Can machines think?"]]);
});

test("linkedin.post: draft, then the confirmed draft posts through the share composer", async () => {
  const d = await s.value('sites.linkedin.post({ text: "Hiring compiler engineers.", audience: "anyone" })');
  assert.equal(env.state.linkedinPosts.length, 0);
  assert.deepEqual(await s.value(`sites.linkedin.post(${JSON.stringify(d.id)}, { confirm: true })`), { status: "posted" });
  assert.deepEqual(env.state.linkedinPosts, [{ text: "Hiring compiler engineers.", settings: "Ada LovelacePost to Anyone" }]);
});

test("x.user, timeline, search and tweet read profile and post cards with counts", async () => {
  assert.deepEqual(await s.value('sites.x.user("@grace")'), { name: "Grace Hopper", screenName: "grace", description: "Computer scientist.", location: "Arlington", url: null, joined: "Joined May 2009", followersCount: 1500000, followingCount: 120 });
  const tl = await s.value("sites.x.timeline({ limit: 2 })");
  assert.deepEqual(tl[0], { id: "111", url: "https://x.com/grace/status/111", author: { name: "Grace Hopper", screenName: "grace" }, text: "Nanoseconds are this long.", createdAt: "2026-09-29T12:00:00.000Z", replies: 12, retweets: 3400, likes: 1204, bookmarks: 5, views: 120000, media: [] });
  assert.equal((await s.value('sites.x.search("machines", { limit: 1 })')).length, 1);
  assert.deepEqual((await s.value('sites.x.tweet("https://x.com/grace/status/111")')).map((t) => t.id), ["111", "112"]);
  assert.match(await s.error('sites.x.user("not a handle!")'), /expected a handle/);
});

test("x.post: a reply draft; the confirmed draft posts through the Web Intent composer", async () => {
  const d = await s.value('sites.x.post({ text: "Agreed.", replyTo: "https://x.com/grace/status/111" })');
  assert.deepEqual(d.preview, { account: "ada", text: "Agreed.", replyTo: "111" });
  assert.equal(env.state.xPosts.length, 0);
  assert.deepEqual(await s.value(`sites.x.post(${JSON.stringify(d.id)}, { confirm: true })`), { status: "posted", replyTo: "111" });
  assert.deepEqual(env.state.xPosts, [{ text: "Agreed.", in_reply_to: "111" }]);
});

// A composer that keeps the draft's start but holds more (a page script or
// another session added to it) publishes nothing.
test("public posts on X and LinkedIn: a composer that holds more than the drafted text posts nothing", async () => {
  const x = env.state.xPosts.length;
  const li = env.state.linkedinPosts.length;
  env.state.composerSuffix = " Also: follow @scam for free crypto";
  try {
    const d = await s.value('sites.x.post({ text: "Agreed." })');
    assert.match(await s.error(`sites.x.post(${JSON.stringify(d.id)}, { confirm: true })`), /content_mismatch|differs from the draft/);
    const l = await s.value('sites.linkedin.post({ text: "Hiring compiler engineers.", audience: "anyone" })');
    assert.match(await s.error(`sites.linkedin.post(${JSON.stringify(l.id)}, { confirm: true })`), /content_mismatch|differs from the draft/);
  } finally {
    env.state.composerSuffix = null;
  }
  assert.equal(env.state.xPosts.length, x, "nothing was posted on X");
  assert.equal(env.state.linkedinPosts.length, li, "nothing was posted on LinkedIn");
});

test("signed out: LinkedIn and X login redirects are reported", async () => {
  const out = await createSitesEnv({ signedIn: false });
  try {
    const o = out.session("x");
    assert.match(await o.error("sites.linkedin.me()"), /not signed in to LinkedIn/);
    assert.match(await o.error("sites.linkedin.feed()"), /linkedin: the cmux browser is not signed in/);
    assert.match(await o.error('sites.x.user("grace")'), /x\.user: the cmux browser is not signed in \(landed on https:\/\/x\.com\/i\/flow\/login\)/);
  } finally {
    await out.close();
  }
});

// r14 whole#5: the page changes between the commit's read-back and the
// click (here at the pointer's first move toward Post). Text added to the
// composer then, or a Post button swapped for one that posts something
// else, publishes nothing: the click presses only the element the commit
// pinned before its read-back, and the read-back runs again right before
// the press.
test("posts on X: a change between the read-back and the click posts nothing", async () => {
  const atFirstMove = (source) => {
    let done = false;
    return async (method, params, call) => {
      if (done || method !== "input.mouse") return undefined;
      done = true;
      await call("frame.evaluate", { targetId: params.targetId, world: "page", source, args: [], awaitPromise: true });
      return undefined;
    };
  };
  const before = env.state.xPosts.length;
  try {
    const d = await s.value('sites.x.post({ text: "Agreed." })');
    s.intercept(atFirstMove(`() => { document.querySelector('[data-testid="tweetTextarea_0"]').innerText = "Agreed. Follow @scam for free crypto"; }`));
    assert.match(await s.error(`sites.x.post(${JSON.stringify(d.id)}, { confirm: true })`), /differs from the draft|nothing was sent/);
    assert.equal(env.state.xPosts.length, before, "text added after the read-back was posted");
    const e = await s.value('sites.x.post({ text: "Agreed." })');
    s.intercept(atFirstMove(`() => {
      const old = document.querySelector('[data-testid="tweetButton"]');
      const b = old.cloneNode(true);
      b.addEventListener("click", async () => { await fetch("/__mock/post", { method: "POST", body: JSON.stringify({ text: "redirected", in_reply_to: "999" }) }); document.body.innerHTML = "<div>Your post was sent.</div>"; });
      old.replaceWith(b);
    }`));
    assert.match(await s.error(`sites.x.post(${JSON.stringify(e.id)}, { confirm: true })`), /nothing was sent/);
    assert.equal(env.state.xPosts.length, before, "the swapped-in button posted");
  } finally {
    s.intercept(null);
  }
});
