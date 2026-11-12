// A site tool's tab is bound to the site's origin: a redirect that takes the
// write's tab to another origin (mirror.example, a copy of the site's pages
// whose requests would still land) gets no read-back, input or click there.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("tab-origin");

// Drafts `draft`, then confirms it with the write's page load on `host`
// (path matching `path`) redirected to mirror.example; returns the error.
async function confirmRedirected(draft, host, path) {
  const d = await s.value(draft);
  assert.equal(d.status, "draft");
  env.state.mirrorRequests.length = 0;
  env.state.tabRedirect = { host, path };
  try {
    return await s.error(`sites.${d.site}.${d.action}(${JSON.stringify(d.id)}, { confirm: true })`);
  } finally {
    env.state.tabRedirect = null;
  }
}

function assertRefused(error, writes) {
  assert.ok(env.state.mirrorRequests.length > 0, "the redirect reached mirror.example");
  assert.deepEqual(writes, [], "a write landed through the redirected tab");
  // The target_mismatch error.
  assert.match(error || "", /the site's tab left https:\/\/[\w.]+ for https:\/\/mirror\.example/, error);
}

test("x.post: a compose tab redirected to another origin posts nothing", async () => {
  const error = await confirmRedirected('sites.x.post("Bound to x.com.")', "x.com", /^\/intent\/post/);
  assertRefused(error, env.state.xPosts);
});

test("linkedin.post: a share tab redirected to another origin posts nothing", async () => {
  const error = await confirmRedirected('sites.linkedin.post({ text: "Bound to linkedin.com.", audience: "anyone" })', "www.linkedin.com", /^\/feed\/\?shareActive/);
  assertRefused(error, env.state.linkedinPosts);
});

test("gmail.send: a compose tab redirected to another origin sends nothing", async () => {
  const error = await confirmRedirected('sites.gmail.send({ to: "bob@example.com", subject: "Bound", body: "Bound to mail.google.com." })', "mail.google.com", /view=cm/);
  assertRefused(error, env.state.gmailSent);
});

test("googleCalendar.create: an event editor redirected to another origin saves nothing", async () => {
  const error = await confirmRedirected('sites.googleCalendar.create({ title: "Bound", start: "2026-10-08T17:00:00Z", guests: ["bob@example.com"] })', "calendar.google.com", /eventedit|action=TEMPLATE/);
  assertRefused(error, env.state.calendarCreated);
});

test("googleDocs.append: an editor tab redirected to another origin edits nothing", async () => {
  const DOC = "https://docs.google.com/document/d/1docPRIVATE000000000000000000000x/edit";
  const file = env.state.editors.files.get("1docPRIVATE000000000000000000000x");
  const before = JSON.stringify(file.blocks);
  const error = await confirmRedirected(`sites.googleDocs.append(${JSON.stringify(DOC)}, "Bound to docs.google.com.")`, "docs.google.com", /^\/document\/d\/[\w-]+\/edit/);
  assertRefused(error, JSON.stringify(file.blocks) === before ? [] : [file.blocks.at(-1)]);
});
