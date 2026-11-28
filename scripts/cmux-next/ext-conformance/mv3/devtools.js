"use strict";
CXT.report("devtools", "devtools_page_loaded", "pass", "inspected tab " + chrome.devtools.inspectedWindow.tabId);
chrome.devtools.panels.create("cxt", "icon16.png", "devtools-panel.html", (panel) => {
  CXT.report("devtools", "panels.create", panel ? "pass" : "fail", "");
  panel.onShown.addListener(() => CXT.report("devtools", "panel_shown", "pass", ""));
});
chrome.devtools.inspectedWindow.eval("document.title", (result, error) => {
  CXT.report("devtools", "inspectedWindow.eval", error ? "fail" : "pass", error || result);
});
