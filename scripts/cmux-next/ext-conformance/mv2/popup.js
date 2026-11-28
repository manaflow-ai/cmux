"use strict";
const page = chrome.extension.getBackgroundPage();
CXT.report("mv2", "popup_getBackgroundPage", page && page.CXT ? "pass" : "fail", innerWidth + "x" + innerHeight);
