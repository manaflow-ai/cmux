// Whose browser-context options (session.configure: user agent, headers,
// permissions and the domain policy's content rules) a tab carries: a tab a
// session created carries its creator's while the creator is attached, and
// another session can neither drive that tab nor change its options; a
// user's tab, including one a session only drives, keeps its own. The dev
// driver cannot change the user agent, so there each check holds trivially.
// oracle: skip (session and tab ownership are cmux-defined)
// ---- cell cmux-only
const keptForUser = await tabs.open(`${PRIMARY}/index.html?ctx-user`);
await keptForUser.keep();
// ---- cell session=ctxdriver cmux-only
const setUserAgent = async (ua) => {
  try {
    await session.configure({ userAgent: ua });
    return true;
  } catch (e) {
    if (e.code !== "unsupported") throw e;
    return false;
  }
};
const userRow = (await tabs.list()).find((t) => t.url.endsWith("?ctx-user"));
const userTab = await tabs.use(userRow.id);
const userAgentBefore = await userTab.evaluate(() => navigator.userAgent);
const userAgentApplies = await setUserAgent("brepl-driver-ua");
await userTab.reload();
emitCmux("user-tab-keeps-its-user-agent", (await userTab.evaluate(() => navigator.userAgent)) === userAgentBefore);
const ownTab = await tabs.open(`${PRIMARY}/index.html?ctx-own`);
emitCmux("created-tab-gets-the-user-agent", !userAgentApplies || (await ownTab.evaluate(() => navigator.userAgent)) === "brepl-driver-ua");
await ownTab.close();
await userTab.close();
await setUserAgent(null);
// ---- cell session=ctxowner cmux-only
// The owner's tab keeps the owner's options while another session is
// active. That session cannot drive the owner's tab (a tab another running
// session created is refused), so its own session.configure and its
// refused attempt are the activity the owner's options must survive.
let ownerApplies = true;
try {
  await session.configure({ userAgent: "brepl-owner-ua" });
} catch (e) {
  if (e.code !== "unsupported") throw e;
  ownerApplies = false;
}
const ownerTab = await tabs.open(`${PRIMARY}/index.html?ctx-owner`);
// ---- cell cmux-only
try {
  await session.configure({ userAgent: "brepl-other-ua" });
} catch (e) {
  if (e.code !== "unsupported") throw e;
}
const otherRow = (await tabs.list({ all: true })).find((t) => t.url.endsWith("?ctx-owner"));
let refusal = null;
try {
  const otherView = await tabs.use(otherRow.id);
  await otherView.evaluate(() => document.title);
} catch (e) {
  refusal = e.message;
}
emitCmux("other-session-refused-on-owner-tab", /belongs to the REPL session "ctxowner", which is still running/.test(refusal ?? ""));
// ---- cell session=ctxowner cmux-only
await ownerTab.reload();
emitCmux("owner-options-survive-another-session", !ownerApplies || (await ownerTab.evaluate(() => navigator.userAgent)) === "brepl-owner-ua");
await ownerTab.close();
await session.configure({ userAgent: null }).catch((e) => { if (e.code !== "unsupported") throw e; });
