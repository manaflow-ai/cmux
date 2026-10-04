// A confirmed draft acts as the account that made it, or fails. The draft
// names the account; the confirmation checks it again in the page or
// request that performs the write, right before the write, so another
// session that switches the shared profile's account after the first check
// (while the composer loads) cannot make the draft act as someone else.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("bindings-accounts");

test("linkedin.post: the member is read again in the share composer right before Post; a switch while it loads posts nothing", async () => {
  try {
    await s.run('var lnD = await sites.linkedin.post("Bound to my account.")');
    env.state.linkedinSwitchOnCompose = "mallory";
    const before = env.state.linkedinPosts.length;
    assert.match(await s.error("sites.linkedin.post(lnD.id, { confirm: true })"), /account_changed|mallory/);
    assert.equal(env.state.linkedinPosts.length, before, "nothing was posted as mallory");
    assert.deepEqual(await s.value("lnD.preview"), { account: "ada-lovelace", memberId: 424242, text: "Bound to my account." });
  } finally {
    env.state.linkedinViewer = null;
    env.state.linkedinSwitchOnCompose = null;
  }
});
