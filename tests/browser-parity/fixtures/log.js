// Shared event log. Every page records trusted-ness so scenarios can prove
// input arrived as real user input, not synthetic DOM events.
window.__log = [];
function __record(e) {
  const t = e.target;
  const id = t && t.id ? "#" + t.id : t && t.tagName ? t.tagName.toLowerCase() : String(t);
  window.__log.push({ type: e.type, id, trusted: e.isTrusted, key: e.key, code: e.code, button: e.button, detail: e.detail });
}
for (const type of ["click", "dblclick", "contextmenu", "mousedown", "mouseup", "keydown", "keyup", "input", "change", "focus", "blur", "dragstart", "drop", "wheel", "pointerdown"]) {
  addEventListener(type, __record, true);
}
window.__summary = () => window.__log.map((e) => `${e.type}${e.id ? " " + e.id : ""}${e.key ? " key=" + e.key : ""}${e.trusted ? "" : " UNTRUSTED"}`);
