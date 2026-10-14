import { errorsBetter as errBetter } from "../lib.mjs";
// Raw input and element actions by index: reference A Keyboard.* and Mouse.*;
// reference B AXAPI.*, CUAAPI.*, DomCUAAPI.* (legacy mode) and the clipboard.
const LAB = "/diff/lab.html";
// AX index of the first state line matching `role label`.
const AXI = `const axi = async (re) => { const s = await t.ax.get("state", { disableDiffing: true }); const m = s.match(re); if (!m) throw new Error("AX index missing: " + re); return Number(m[1]); };`;
const CENTER = `const center = async (s) => { const b = await $P.locator(s).evaluate((e) => { const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; }); return { x: Math.round(b[0]), y: Math.round(b[1]) }; };`;
const KEYLOG = `const keylog = async () => $LOG.filter((r) => r[1] === "keys" && r[0] === "keydown").map((r) => [r[3][0], r[3][2], r[3][3], r[3][4], r[3][5]]);`;

export default [
  {
    id: "keyboard.members",
    members: ["reference-a:Keyboard.down", "reference-a:Keyboard.up", "reference-a:Keyboard.press", "reference-a:Keyboard.type", "reference-a:Keyboard.insertText", "reference-b:CUAAPI.keypress", "reference-b:CUAAPI.type"],
    path: LAB,
    code: `${KEYLOG}
await $P.locator("#keys").click();
await $P.keyboard.type("ab");
await $P.keyboard.press("Shift+KeyC");
await $P.keyboard.down("Shift"); await $P.keyboard.press("KeyD"); await $P.keyboard.up("Shift");
await $P.keyboard.insertText("é😀");
await $P.keyboard.press("Backspace");
return { value: await $P.locator("#keys").evaluate((e) => e.value), keys: await keylog(), trusted: $LOG.filter((r) => r[1] === "keys").every((r) => r[2]) };`,
    "reference-b": `${KEYLOG}
await $P.locator("#keys").click();
await t.cua.type({ text: "ab" });
await t.cua.keypress({ keys: ["SHIFT", "c"] });
await t.cua.keypress({ keys: ["SHIFT", "d"] });
await t.cua.type({ text: "é😀" });
await t.cua.keypress({ keys: ["BACKSPACE"] });
return { value: await $P.locator("#keys").evaluate((e) => e.value), keys: await keylog(), trusted: $LOG.filter((r) => r[1] === "keys").every((r) => r[2]) };`,
    referenceBMode: "legacy",
    compare: ["value", "trusted"],
    better: {
      "reference-b": {
        reason: "typed keys arrive as trusted native events; reference B's cua.type delivers untrusted events",
        check: (c, r) => c.trusted === true && r.trusted === false && c.value === r.value,
      },
    },
    expect: { value: "abCDé", trusted: true },
  },
  {
    id: "keyboard.errors",
    members: ["reference-a:Keyboard.press", "reference-b:CUAAPI.keypress", "reference-b:CUAAPI.type", "reference-b:AXAPI.pressKey"],
    path: LAB,
    code: `return { unknown: await E(() => $P.keyboard.press("NoSuchKey")), empty: await E(() => $P.keyboard.press("")), notText: await E(() => $P.keyboard.type(123)) };`,
    "reference-b": `return { unknown: await E(() => t.ax.pressKey(null, "NoSuchKey")), empty: await E(() => t.ax.pressKey(null, "")), notText: await E(() => t.ax.typeText(null, 123)) };`,
    better: {
      "reference-a": errBetter,
      "reference-b": errBetter,
    },
    expect: { unknown: { error: "invalid-arg" }, empty: { error: "invalid-arg" } },
  },
  {
    id: "keyboard.shortcuts",
    edge: "keyboard-shortcuts",
    members: ["reference-a:Keyboard.press", "reference-b:AXAPI.pressKey"],
    path: LAB,
    code: `${KEYLOG}
await $P.locator("#keys").fill("hello world");
await $P.locator("#keys").press("ControlOrMeta+a");
await $P.keyboard.press("Backspace");
await $P.keyboard.type("x");
await $P.keyboard.press("Alt+Shift+KeyK");
await $P.keyboard.press("Control+Shift+ArrowLeft");
return { value: await $P.locator("#keys").evaluate((e) => e.value), combos: (await keylog()).filter((k) => k[1] || k[2] || k[3]).map((k) => k.join(",")) };`,
    "reference-b": `${KEYLOG}
${AXI}
await $P.locator("#keys").fill("hello world");
const i = await axi(/^\\s*(\\d+) text field[^\\n]*Keys/m);
await t.ax.pressKey(i, "Meta+a");
await t.ax.pressKey(null, "Backspace");
await t.ax.typeText(null, "x");
await t.ax.pressKey(null, "Alt+Shift+k");
await t.ax.pressKey(null, "Control+Shift+ArrowLeft");
return { value: await $P.locator("#keys").evaluate((e) => e.value), combos: (await keylog()).filter((k) => k[1] || k[2] || k[3]).map((k) => k.join(",")) };`,
    compare: ["value"],
    expect: { value: "x" },
  },
  {
    id: "mouse.members",
    members: ["reference-a:Mouse.click", "reference-a:Mouse.dblclick", "reference-a:Mouse.down", "reference-a:Mouse.up", "reference-a:Mouse.move", "reference-a:Mouse.wheel", "reference-b:CUAAPI.click", "reference-b:CUAAPI.double_click", "reference-b:CUAAPI.move", "reference-b:CUAAPI.scroll"],
    path: LAB,
    code: `const box = await $P.locator("#canvas").boundingBox();
const x = box.x + 20, y = box.y + 20;
await $P.mouse.click(x, y);
await $P.mouse.click(x, y, { button: "right" });
await $P.mouse.dblclick(x, y);
await $P.mouse.move(x + 30, y + 10, { steps: 3 });
await $P.mouse.down(); await $P.mouse.up();
await $P.mouse.wheel(0, 40);
await sleep(200);
const ev = $LOG.filter((r) => r[1] === "canvas");
return { clicks: ev.filter((r) => r[0] === "click").length, right: ev.some((r) => r[0] === "mousedown" && r[3][2] === 2), moves: ev.filter((r) => r[0] === "mousemove").length >= 2, at: ((p) => !!p && Math.abs(p[0] - 20) <= 1.5 && Math.abs(p[1] - 20) <= 2)(ev.filter((r) => r[0] === "click").map((r) => [r[3][0], r[3][1]])[0]), wheel: ev.some((r) => r[0] === "wheel"), trusted: ev.every((r) => r[2]) };`,
    "reference-b": `${CENTER}
const c = await center("#canvas");
const x = c.x - 40, y = c.y - 10;
await t.cua.click({ x, y });
await t.cua.click({ x, y, button: 3 });
await t.cua.double_click({ x, y });
await t.cua.move({ x: x + 30, y: y + 10 });
await t.cua.scroll({ x, y, scrollX: 0, scrollY: 40 });
await $P.waitForTimeout(200);
const ev = $LOG.filter((r) => r[1] === "canvas");
return { clicks: ev.filter((r) => r[0] === "click").length, right: ev.some((r) => r[0] === "mousedown" && r[3][2] === 2), moves: ev.filter((r) => r[0] === "mousemove").length >= 1, at: ((p) => !!p && Math.abs(p[0] - 20) <= 1.5 && Math.abs(p[1] - 20) <= 2)(ev.filter((r) => r[0] === "click").map((r) => [r[3][0], r[3][1]])[0]), wheel: ev.some((r) => r[0] === "wheel"), trusted: ev.every((r) => r[2]) };`,
    referenceBMode: "legacy",
    compare: { "reference-a": ["clicks", "right", "moves", "at", "wheel", "trusted"], "reference-b": ["right", "moves", "at", "wheel", "trusted"] },
    expect: { clicks: 4, right: true, moves: true, at: true, wheel: true, trusted: true },
  },
  {
    id: "cua.options",
    members: ["reference-b:CUAAPI.click", "reference-b:CUAAPI.double_click", "reference-b:CUAAPI.drag", "reference-b:CUAAPI.move", "reference-b:CUAAPI.scroll", "reference-b:CUAAPI.keypress", "reference-b:CUAAPI.type"],
    path: LAB,
    code: `const box = await $P.locator("#action").boundingBox();
const x = box.x + box.width / 2, y = box.y + box.height / 2;
await $P.keyboard.down("Shift");
await $P.mouse.click(x, y);
await $P.keyboard.up("Shift");
const shift = $LOG.filter((r) => r[1] === "action" && r[0] === "click").map((r) => r[3][5]);
return {
  shiftClick: shift[shift.length - 1],
  errors: { click: await E(() => $P.mouse.click()), move: await E(() => $P.mouse.move()), wheel: await E(() => $P.mouse.wheel()), type: await E(() => $P.keyboard.type()), press: await E(() => $P.keyboard.press()) },
};`,
    "reference-b": `${CENTER}
const { x, y } = await center("#action");
await t.cua.click({ x, y, button: 1, keypress: ["SHIFT"] });
const shift = $LOG.filter((r) => r[1] === "action" && r[0] === "click").map((r) => r[3][5]);
return {
  shiftClick: shift[shift.length - 1],
  errors: { click: await E(() => t.cua.click({})), move: await E(() => t.cua.move({})), wheel: await E(() => t.cua.scroll({})), type: await E(() => t.cua.type({})), press: await E(() => t.cua.keypress({})) },
};`,
    referenceBMode: "legacy",
    "reference-a": null,
    na: { "reference-a": "covered by mouse.members and keyboard.errors" },
    better: {
      "reference-b": {
        reason: "missing coordinates or keys fail with an argument error naming the parameter",
        check: (c, r, h) => c.shiftClick === true && Object.values(c.errors).every((e) => h.classifyError(e.error) === "invalid-arg"),
      },
    },
    expect: { shiftClick: true, errors: { click: { error: "invalid-arg" }, move: { error: "invalid-arg" }, wheel: { error: "invalid-arg" }, type: { error: "invalid-arg" }, press: { error: "invalid-arg" } } },
  },
  {
    id: "cua.download-media",
    members: ["reference-b:CUAAPI.downloadMedia", "reference-b:DomCUAAPI.downloadMedia"],
    path: "/diff/files.html",
    code: `const box = await $P.locator("#dl-cd").boundingBox();
const wait = $P.waitForEvent("download");
await $P.mouse.click(box.x + 5, box.y + 5);
const d = await wait;
return { name: d.suggestedFilename(), body: fs.readFileSync(await d.path(), "utf8") };`,
    "reference-b": `${CENTER}
const c = await center("#dl-cd");
const r = await E(() => t.cua.downloadMedia({ x: c.x, y: c.y, timeoutMs: 5000 }));
return { name: r.error ? r : "downloaded", body: null };`,
    referenceBMode: "legacy",
    "reference-a": null,
    na: { "reference-a": "Reference A downloads are covered by loc.download-media and edge downloads" },
    better: {
      "reference-b": {
        reason: "a click at a point starts the download and the file is readable; reference B's Chrome backend does not support cua_download_media",
        check: (c, r) => c.name === "cd-a.txt" && typeof r.name === "object",
      },
    },
    expect: { name: "cd-a.txt", body: "cd body a\n" },
  },
  {
    id: "dom-cua.forms",
    members: ["reference-b:DomCUAAPI.click", "reference-b:DomCUAAPI.double_click", "reference-b:DomCUAAPI.keypress", "reference-b:DomCUAAPI.scroll", "reference-b:DomCUAAPI.type", "reference-b:DomCUAAPI.get_visible_dom", "reference-b:Tab.dom_cua"],
    path: LAB,
    code: `const s = String((await snapshot({ interactive: true })).tree);
const ref = (s.match(/button "Action"[^\\n]*?\\[ref=(\\w+)\\]/) || [])[1];
const nameRef = (s.match(/textbox "Name"[^\\n]*?\\[ref=(\\w+)\\]/) || [])[1];
await page.locator(ref).click();
await page.locator(ref).dblclick();
await page.locator(nameRef).click();
await page.keyboard.press("End");
await page.keyboard.type("X");
await page.mouse.wheel(0, 300);
await sleep(300);
return { status: await page.locator("#status").innerText(), dbl: $LOG.some((r) => r[1] === "action" && r[0] === "dblclick"), value: await page.locator("#name").inputValue(), scrolled: (await page.evaluate(() => scrollY)) > 0, badRef: await E(() => page.locator("e99999").click($T(300))) };`,
    "reference-b": `const dom = await t.dom_cua.get_visible_dom();
const text = typeof dom === "string" ? dom : JSON.stringify(dom);
const find = (label) => { const m = text.match(new RegExp("(?:node_id|id)[\\"=: ]+\\"?(\\\\w+)\\"?[^\\\\n{}]{0,200}" + label)) || text.match(new RegExp(label + "[^\\\\n{}]{0,200}?(?:node_id|id)[\\"=: ]+\\"?(\\\\w+)")); return m ? m[1] : null; };
const aid = find("Action");
const nid = find("Name");
const d = t.dom_cua;
const click = await E(() => d.click({ node_id: aid }));
const dbl = await E(() => d.double_click({ node_id: aid }));
await E(() => d.click({ node_id: nid }));
await E(() => d.keypress({ keys: ["END"] }));
await E(() => d.type({ text: "X" }));
await E(() => d.scroll({ x: 0, y: 300 }));
await $P.waitForTimeout(300);
return { status: await $P.locator("#status").innerText(), dbl: $LOG.some((r) => r[1] === "action" && r[0] === "dblclick"), value: await $P.locator("#name").evaluate((e) => e.value), scrolled: (await $P.evaluate(() => scrollY)) > 0, badRef: await E(() => d.click({ node_id: "nope" })), _ids: [aid, nid, text.slice(0, 300), click, dbl] };`,
    referenceBMode: "legacy",
    "reference-a": null,
    na: { "reference-a": "Reference A acts on snapshot refs with locators, covered by snapshot.full" },
    better: {
      "reference-b": errBetter,
    },
    expect: { status: "clicked", dbl: true, value: "initialX", scrolled: true, badRef: { error: "no-element" } },
  },
  {
    id: "ax.click-forms",
    members: ["reference-b:AXAPI.click"],
    path: LAB,
    code: `const s = String((await snapshot()).tree);
const ref = (s.match(/button "Action"[^\\n]*?\\[ref=(\\w+)\\]/) || [])[1];
const l = page.locator(ref);
const box = await l.boundingBox();
const n = async (k) => $LOG.filter((r) => r[1] === "action" && r[0] === k).length;
await l.click(); const byRef = await n("click");
await page.mouse.click(box.x + 3, box.y + 3); const byPoint = await n("click");
await l.click({ clickCount: 2 }); const dbl = await n("dblclick");
await l.click({ button: "right" }); const right = await n("contextmenu");
await l.click({ button: "middle" }); const middle = await n("auxclick");
return { byRef, byPoint, dbl, right, middle };`,
    "reference-b": `${AXI}
const i = await axi(/^\\s*(\\d+) button Action/m);
const box = await $P.locator("#action").evaluate((e) => { const r = e.getBoundingClientRect(); return [r.x + 3, r.y + 3]; });
const n = async (k) => $LOG.filter((r) => r[1] === "action" && r[0] === k).length;
await t.ax.click(i); const byRef = await n("click");
await t.ax.click(box); const byPoint = await n("click");
await t.ax.click(i, { clickCount: 2 }); const dbl = await n("dblclick");
await t.ax.click(i, { mouseButton: "right" }); const right = await n("contextmenu");
await t.ax.click(i, { mouseButton: "middle" }); const middle = await n("auxclick");
return { byRef, byPoint, dbl, right, middle };`,
    "reference-a": null,
    na: { "reference-a": "covered by loc.click.options" },
    expect: { byRef: 1, byPoint: 2, dbl: 1, right: 1, middle: 2 },
  },
  {
    id: "ax.text-forms",
    members: ["reference-b:AXAPI.setValue", "reference-b:AXAPI.typeText", "reference-b:AXAPI.pressKey", "reference-b:AXAPI.paste", "reference-b:AXAPI.selectText", "reference-b:TabClipboardAPI.writeText"],
    path: LAB,
    code: `const l = page.locator("#name");
const v = () => l.evaluate((e) => [e.value, e.selectionStart, e.selectionEnd]);
const out = {};
await l.fill("set"); out.set = await v();
await l.pressSequentially("T"); out.typed = await v();
await l.press("End"); await l.press("a"); out.pressed = await v();
await page.clipboard.writeText("P"); await l.press("ControlOrMeta+v"); out.pasted = await v();
await l.evaluate((e) => e.setSelectionRange(0, 3)); out.select = await v();
await l.evaluate((e) => e.setSelectionRange(3, 3)); out.before = await v();
return out;`,
    "reference-b": `${AXI}
const i = await axi(/^\\s*(\\d+) text field[^\\n]*\\bName\\b/m);
const v = () => $P.locator("#name").evaluate((e) => [e.value, e.selectionStart, e.selectionEnd]);
const out = {};
await t.ax.setValue(i, "set"); out.set = await v();
await t.ax.typeText(i, "T"); out.typed = await v();
await t.ax.pressKey(null, "End"); await t.ax.pressKey(i, "a"); out.pressed = await v();
await t.ax.paste(i, "P"); out.pasted = await v();
await t.ax.selectText(i, "set"); out.select = await v();
await t.ax.selectText(i, "T", { selectionType: "cursor_before" }); out.before = await v();
return out;`,
    "reference-a": null,
    na: { "reference-a": "Reference A acts by locator; typing and paste are covered by loc.typing and clipboard cases" },
    expect: { set: ["set", 3, 3], typed: ["setT", 4, 4], pressed: ["setTa", 5, 5], pasted: ["setTaP", 6, 6], select: ["setTaP", 0, 3], before: ["setTaP", 3, 3] },
  },
  {
    id: "ax.scroll-forms",
    members: ["reference-b:AXAPI.scroll", "reference-b:DomCUAAPI.scroll"],
    path: LAB,
    code: `const sc = page.locator("#scroller");
const box = await sc.boundingBox();
await page.mouse.move(box.x + 20, box.y + 20);
await page.mouse.wheel(0, 100);
await sleep(300);
const inner = await sc.evaluate((e) => e.scrollTop > 0);
await page.mouse.move(400, 300);
await page.mouse.wheel(0, 600);
await sleep(300);
return { inner, page: (await page.evaluate(() => scrollY)) > 0 };`,
    "reference-b": `${AXI}
const i = await axi(/^\\s*(\\d+) [^\\n]*Outer scroller/m);
await t.ax.scroll(i, "down", 1);
await $P.waitForTimeout(400);
const inner = await $P.locator("#scroller").evaluate((e) => e.scrollTop > 0);
await t.ax.scroll([400, 300], "down", 1);
await $P.waitForTimeout(400);
return { inner, page: (await $P.evaluate(() => scrollY)) > 0 };`,
    "reference-a": null,
    na: { "reference-a": "covered by mouse.members (Mouse.wheel) and edge.nested-scroll" },
    expect: { inner: true, page: true },
  },
  {
    id: "ax.secondary-action",
    members: ["reference-b:AXAPI.performSecondaryAction"],
    path: LAB,
    code: `await page.locator("#action").click({ button: "right" });
return { contextmenu: $LOG.filter((r) => r[1] === "action" && r[0] === "contextmenu").length, bad: await E(() => page.locator("e99999").click({ button: "right", timeout: 300 })) };`,
    "reference-b": `${AXI}
const i = await axi(/^\\s*(\\d+) button Action/m);
const menu = await E(() => t.ax.performSecondaryAction(i, "AXShowMenu"));
return { contextmenu: $LOG.filter((r) => r[1] === "action" && r[0] === "contextmenu").length, bad: await E(() => t.ax.performSecondaryAction(99999, "Nope")), _menu: menu };`,
    "reference-a": null,
    na: { "reference-a": "Reference A has no accessibility actions; its right click is covered by loc.click.options" },
    better: {
      "reference-b": {
        reason: "a right click opens the context menu event; reference B's performSecondaryAction('AXShowMenu') delivers none",
        check: (c, r) => c.contextmenu === 1 && r.contextmenu === 0,
      },
    },
    expect: { contextmenu: 1, bad: { error: "no-element" } },
  },
  {
    id: "clipboard.members",
    members: ["reference-b:TabClipboardAPI.read", "reference-b:TabClipboardAPI.readText", "reference-b:TabClipboardAPI.write", "reference-b:TabClipboardAPI.writeText", "reference-b:Tab.clipboard"],
    path: LAB,
    code: `const c = page.clipboard;
await c.writeText("plain text");
const text = await c.readText();
await c.write([{ entries: [{ mimeType: "text/plain", text: "plain" }, { mimeType: "text/html", text: "<b>bold</b>" }] }]).catch(async () => c.write([{ "text/plain": "plain", "text/html": "<b>bold</b>" }]));
const items = await c.read();
await page.locator("#area").fill("");
await page.locator("#area").focus();
await page.keyboard.press("ControlOrMeta+v");
return { text, mimes: JSON.stringify(items).includes("text/html"), pasted: await page.locator("#area").inputValue(), empty: await E(() => c.write([])), notText: await E(() => c.writeText(123)) };`,
    "reference-b": `const c = t.clipboard;
await c.writeText("plain text");
const text = await c.readText();
await c.write([{ entries: [{ mimeType: "text/plain", text: "plain" }, { mimeType: "text/html", text: "<b>bold</b>" }] }]);
const items = await c.read();
await $P.locator("#area").fill("");
${AXI}
const i = await axi(/^\\s*(\\d+) text entry area[^\\n]*Notes/m);
await t.ax.paste(i, (await c.readText()));
return { text, mimes: JSON.stringify(items).includes("text/html"), pasted: await $P.locator("#area").evaluate((e) => e.value), empty: await E(() => c.write([])), notText: await E(() => c.writeText(123)) };`,
    "reference-a": null,
    na: { "reference-a": "Reference A has no clipboard API" },
    better: {
      "reference-b": errBetter,
    },
    expect: { text: "plain text", mimes: true, pasted: "plain", empty: { error: "invalid-arg" }, notText: { error: "invalid-arg" } },
  },
  {
    id: "dev.logs",
    members: ["reference-b:TabDevAPI.logs"],
    path: LAB,
    code: `await page.evaluate(() => { console.debug("lv-debug"); console.info("lv-info"); console.log("lv-log"); console.warn("lv-warn"); console.error("lv-error"); });
await sleep(100);
const m = (r) => r.filter((x) => x.text().startsWith("lv-")).map((x) => x.type());
return {
  all: m(await page.consoleMessages()), warn: m(await page.consoleMessages({ level: "warning" })), error: m(await page.consoleMessages({ level: "error" })),
  limited: m(await page.consoleMessages({ filter: "lv-", limit: 2 })).length,
  badLimit: await E(() => page.consoleMessages({ limit: 0 })), badLevel: await E(() => page.consoleMessages({ level: "unknown" })), badFilter: await E(() => page.consoleMessages({ filter: 2 })),
};`,
    "reference-b": `await $P.locator("#log-btn").click();
const m = (r) => r.filter((x) => String(x.message).startsWith("lv-")).map((x) => x.level);
return {
  all: m(await t.dev.logs({})), warn: m(await t.dev.logs({ levels: ["warn"] })), error: m(await t.dev.logs({ levels: ["error"] })),
  limited: m(await t.dev.logs({ filter: "lv-", limit: 2 })).length,
  badLimit: await E(() => t.dev.logs({ limit: 0 })), badLevel: await E(() => t.dev.logs({ levels: ["unknown"] })), badFilter: await E(() => t.dev.logs({ filter: 2 })),
};`,
    "reference-a": null,
    na: { "reference-a": "Reference A has no console history; page.on('console') is covered by page.on-off" },
    compare: ["badLimit", "badLevel", "badFilter"],
    better: {
      "reference-b": {
        reason: "console history keeps page-evaluated messages at every level; reference B's read-only evaluate cannot log and its Chrome log capture misses them",
        check: (c, r) => c.all.length === 5 && r.all.length < 5,
      },
    },
    expect: { all: ["debug", "info", "log", "warning", "error"], warn: ["warning"], error: ["error"], limited: 2, badLimit: { error: "invalid-arg" }, badLevel: { error: "invalid-arg" }, badFilter: { error: "invalid-arg" } },
  },
];
