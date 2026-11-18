// As Bitwarden's BrowserFido2UserInterfaceSession: open a popout with chrome.windows.create, keep the window id it
// returns, and fall back (abort(true)) when chrome.windows.onRemoved fires for that id. Every window event is kept in
// storage.session (key "events") so a test can read what the extension saw.
const events = [];
let openerTab = null;
const note = (event) => {
  events.push({ t: Date.now(), event });
  chrome.storage.session.set({ events });
  // The opener page keeps the same log (window.__probe), so a test reads one place.
  if (openerTab != null) chrome.tabs.sendMessage(openerTab, { probeEvent: event }).catch(() => {});
};
chrome.windows.onRemoved.addListener((id) => note(`windows.onRemoved ${id}`));
chrome.windows.onCreated.addListener((w) => note(`windows.onCreated ${w.id} type=${w.type}`));
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message?.probe?.type !== "get") return false;
  openerTab = sender.tab.id;
  (async () => {
    const opener = await chrome.windows.get(sender.tab.windowId);
    const popout = await chrome.windows.create({
      url: chrome.runtime.getURL("popout.html"), type: "popup", focused: true, width: 380, height: 420,
      left: opener.left + opener.width - 395, top: opener.top + 90,
    });
    note(`popout created ${popout.id} (opener window ${sender.tab.windowId})`);
    const onRemoved = (id) => {
      if (id !== popout.id) return;
      chrome.windows.onRemoved.removeListener(onRemoved);
      note(`popout ${id} closed: fallback`);
      reply({ fallbackRequested: true, popout: popout.id });
    };
    chrome.windows.onRemoved.addListener(onRemoved);
  })().catch((error) => { note(`error ${error}`); reply({ error: String(error) }); });
  return true;
});
