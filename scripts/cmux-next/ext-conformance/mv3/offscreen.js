"use strict";
const parsed = new DOMParser().parseFromString("<p id=x>cxt</p>", "text/html").getElementById("x").textContent;
chrome.runtime.sendMessage({ type: "offscreen-ready", parsed });
