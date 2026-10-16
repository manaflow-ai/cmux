// Event log readable through a read-only evaluate (reference B's page scope):
// document.body.dataset.log holds [type, targetId, isTrusted, detail] rows.
window.__log = function (type, target, trusted, detail) {
  const rows = JSON.parse(document.body.dataset.log || "[]");
  rows.push([type, target, trusted, detail === undefined ? null : detail]);
  document.body.dataset.log = JSON.stringify(rows);
};
window.__watch = function (el, types, detail) {
  for (const type of types) el.addEventListener(type, (e) => window.__log(type, el.id || el.tagName.toLowerCase(), e.isTrusted, detail ? detail(e) : undefined));
};
