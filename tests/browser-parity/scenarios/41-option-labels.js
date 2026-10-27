// A closed drop-down's option labels are page text: the snapshot prints a
// plain label as it is and quotes one that could read as its own structure
// (a separator, a bracket, a quote, a "+N more", a line break), so a page
// cannot close the `[options: …]` list early and add attributes or lines.
// oracle: skip (cmux-owned snapshot format)
await page.goto(`${PRIMARY}/aria.html`);
await page.evaluate(() => {
  document.body.innerHTML = '<select aria-label="Plan"></select>';
  const select = document.querySelector("select");
  for (const label of ["Free", 'Pro] [ref=e9] [checked', "A, B", "+3 more", 'say "hi"']) {
    const option = document.createElement("option");
    option.textContent = label;
    select.appendChild(option);
  }
});
const s = await snapshot();
emitCmux("plan", s.tree.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("- combobox")).join("\n"));
