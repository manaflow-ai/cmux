// Aside-compatible REPL names (plans/cmux-next/computer-use-lead.md, Codemode
// parity): thin wrappers over `tabs.*`, `screenshot` and the session's
// directory, so a script written for `aside repl` runs here unchanged.
// Nothing here adds behavior: each name calls the cmux API it names.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});

  function install({ globals, tabs, screenshot, workDir, state }) {
    const targetOf = (tab) => (tab && typeof tab === "object" ? tab.targetId || tab.id : tab);

    // Aside's tab rows: { targetId, title, url, active }, plus cmux's state and workspace.
    async function listBrowserTabs() {
      const rows = await tabs.list({ all: true });
      return rows.map((t) => ({ targetId: t.id, title: t.title, url: t.url, active: t.active, state: t.state, workspace: t.workspace }));
    }

    // Attaches an open browser tab (a row of listBrowserTabs() or its targetId) and makes it `page`.
    function attachBrowserTab(targetId) {
      return tabs.use(targetOf(targetId));
    }

    // The tab the person sees: the active tab of this workspace, else of any window.
    async function attachActiveBrowserTab() {
      const pick = (await tabs.list()).find((t) => t.active) || (await tabs.list({ all: true })).find((t) => t.active);
      if (!pick) throw new Error("attachActiveBrowserTab: no browser tab is active; see listBrowserTabs()");
      return tabs.use(pick.id);
    }

    function getTabByTargetId(targetId) {
      return tabs.get(targetOf(targetId));
    }

    // Opens a tab (in the background of the person's UI), waits for its load and makes it `page`.
    function openTab(url, options) {
      return tabs.open(url, options || {});
    }

    // Closes a tab (a Page, a row or a targetId; `page` when omitted). After
    // closing `page`, the next use of `page` opens a new tab.
    async function closeTab(tab) {
      const target = tab === undefined ? state.current : typeof tab === "string" || (tab && !tab.close) ? await tabs.get(targetOf(tab)) : tab;
      if (!target) return;
      await target.close();
      if (state.current === target) state.current = null;
    }

    // screenshot() with each interactive ref's box and label drawn on the page.
    function annotatedScreenshot(target, options) {
      return screenshot(target, { ...(options || {}), annotate: true });
    }

    // The session's directory: `pwd()`, or `pwd` where a string is expected.
    const pwd = () => workDir();
    pwd.toString = workDir;
    pwd[Symbol.toPrimitive] = workDir;

    Object.assign(globals, { listBrowserTabs, attachBrowserTab, attachActiveBrowserTab, getTabByTargetId, openTab, closeTab, annotatedScreenshot, pwd });
  }

  ns.asideCompat = { install };
})(typeof globalThis !== "undefined" ? globalThis : this);
