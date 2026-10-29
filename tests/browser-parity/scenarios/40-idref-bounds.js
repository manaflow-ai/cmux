// A page sets the length of an IDREF list (aria-labelledby, aria-owns) and
// of a slot name: the snapshot reads at most the first 4,096 characters of
// a list (an id cut there is dropped, and a name with a longer list is read
// directly from the element), and never escapes a longer slot name into a
// selector (each host child is asked which slot took it).
// oracle: skip (cmux-owned page-read bound)
await page.goto(`${PRIMARY}/aria.html`);
await page.evaluate(() => {
  const pad = " ".repeat(5000);
  const long = "s".repeat(5000);
  document.body.innerHTML = '<div role="listbox" aria-label="L" id="lb"></div><div style="display:none"><div id="x" role="option">Owned</div><span id="h">Other</span></div><button id="b">Own</button><div id="host"></div>';
  document.getElementById("lb").setAttribute("aria-owns", pad + "x");
  document.getElementById("b").setAttribute("aria-labelledby", pad + "h");
  const host = document.getElementById("host");
  const slotted = host.appendChild(document.createElement("button"));
  slotted.textContent = "Slotted";
  slotted.setAttribute("slot", long);
  const shadow = host.attachShadow({ mode: "open" });
  shadow.innerHTML = '<div role="group" aria-label="G"><slot><button>Fallback</button></slot></div>';
  shadow.querySelector("slot").setAttribute("name", long);
});
const s = await snapshot({ maxChars: Infinity });
emitCmux("roles", s.tree.split("\n").map((l) => l.trim()).filter((l) => /^- (listbox|option|button|group)/.test(l)).map((l) => l.replace(/ \[ref=\w+\]/, "").replace(/:$/, "")).join("\n"));
