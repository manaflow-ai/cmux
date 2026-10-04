// A confirmed or credentialed page-tool call acts only as the tab and the
// preview it came from: pageAssets.bundle sends the inventory tab's cookies
// only to that tab's own origin (read from the browser, not from the page or
// the returned inventory), and a WebMCP draft runs only the tool it previewed.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("bindings-pages");

test("pageAssets.bundle: an origin named by the inventory or reached by a redirect never gets the profile's cookies", async () => {
  // Agent code edits the returned inventory (as page data can lead it to):
  // it names another site as the page and adds that site's URLs.
  await s.run(`await page.goto("https://assets.example/xpage");
    var forgedInv = await sites.pageAssets.list();
    try { forgedInv.pageUrl = "https://github.com/acme"; } catch (e) {}
    try { forgedInv.assets.push({ id: "forged", kind: "image", name: "private.png", url: "https://github.com/acme/private/raw/HEAD/README.md", sources: [] }, { id: "hop", kind: "image", name: "hop.png", url: "https://assets.example/img/redirect-out.png", sources: [] }); } catch (e) {}`);
  const before = env.state.requests.length;
  await s.value('sites.pageAssets.bundle(forgedInv.id, { kinds: ["image"] })');
  const reqs = env.state.requests.slice(before);
  const github = reqs.filter((r) => r.url.startsWith("https://github.com/"));
  assert.ok(github.length >= 2, "the forged asset and the redirect target were requested");
  assert.deepEqual(github.map((r) => [r.url, r.cookie]), github.map((r) => [r.url, ""]), "no github.com cookie left the profile");
  const own = reqs.filter((r) => r.url === "https://assets.example/img/logo.png");
  assert.ok(own.length && own.every((r) => r.cookie.includes("asset_session=asset-session-secret")), "the tab's own origin keeps its cookie");
});
