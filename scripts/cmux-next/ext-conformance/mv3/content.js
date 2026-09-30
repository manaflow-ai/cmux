// Declared content script, all frames. Reports the frame it runs in, answers
// tabs.sendMessage, talks to the worker, and gives the page the
// web_accessible_resources URLs to fetch.
"use strict";
(() => {
  const params = new URLSearchParams(location.search);
  const frame = window === top ? "top" : (params.get("n") === "cross" ? "cross_origin_iframe" : "same_origin_iframe");
  CXT.report("content_scripts", "all_frames." + frame, "pass", location.href);
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === "ping") sendResponse({ pong: true, frame });
  });
  if (frame !== "top") return;
  chrome.runtime.sendMessage({ type: "content-hello" }).then(
    (reply) => CXT.report("runtime", "sendMessage_content_to_sw", reply && reply.ok ? "pass" : "fail", reply),
    (error) => CXT.report("runtime", "sendMessage_content_to_sw", "fail", error.message));
  window.postMessage({ cxtWar: chrome.runtime.getURL("war.txt"), cxtPrivate: chrome.runtime.getURL("private.txt") }, "*");
})();
