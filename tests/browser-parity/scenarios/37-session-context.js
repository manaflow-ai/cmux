// Whose browser-context options (session.configure: user agent, headers,
// permissions and the domain policy's content rules) a tab carries: a tab a
// session created carries its creator's while the creator is attached; a
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
// The owner's tab keeps the owner's options while another session drives it
// and after that session ends.
let ownerApplies = true;
try {
  await session.configure({ userAgent: "brepl-owner-ua" });
} catch (e) {
  if (e.code !== "unsupported") throw e;
  ownerApplies = false;
}
const ownerTab = await tabs.open(`${PRIMARY}/index.html?ctx-owner`);
await ownerTab.evaluate((applies) => localStorage.setItem("ctxOwnerApplies", String(applies)), ownerApplies);
// ---- cell cmux-only
const otherRow = (await tabs.list()).find((t) => t.url.endsWith("?ctx-owner"));
const otherView = await tabs.use(otherRow.id);
try {
  await session.configure({ userAgent: "brepl-other-ua" });
} catch (e) {
  if (e.code !== "unsupported") throw e;
}
await otherView.evaluate(() => document.title);
// ---- cell cmux-only
// A third session with no options of its own reloads the tab after the
// second one ended.
const observedRow = (await tabs.list()).find((t) => t.url.endsWith("?ctx-owner"));
const observed = await tabs.use(observedRow.id);
await observed.reload();
const observedUserAgent = await observed.evaluate(() => [navigator.userAgent, localStorage.getItem("ctxOwnerApplies")]);
emitCmux("owner-options-survive-another-session", observedUserAgent[1] !== "true" || observedUserAgent[0] === "brepl-owner-ua");
