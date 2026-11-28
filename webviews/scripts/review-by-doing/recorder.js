// Review by doing (cmuxterm-hq#23817): the in-page recorder. Inject it into a gallery stage (or any
// cmux browser tab on a candidate) and every click, typed text, key and drag the reviewer makes is
// kept as a semantic step (recording.ts `Step`) on `window.__cmuxReview.steps`, never a coordinate.
// `window.__cmuxReview.point(element)` turns the element the reviewer points at into a target for
// an expectation. A password field's text is never read; typed text is kept only from text fields.
// Nothing is kept until `start()`: a gallery variant's own play (opening a menu) is the stage, not
// the reviewer's gesture.
(() => {
  if (window.__cmuxReview) return;
  const steps = [];
  let armed = false;
  const IMPLICIT = { BUTTON: "button", A: "link", SELECT: "combobox", TEXTAREA: "textbox", SUMMARY: "button" };
  const ROLES = new Set([
    "button",
    "link",
    "menuitem",
    "menuitemradio",
    "menuitemcheckbox",
    "option",
    "checkbox",
    "radio",
    "switch",
    "tab",
    "textbox",
    "combobox",
    "slider",
    "separator",
    "dialog",
    "menu",
    "listbox",
  ]);
  const roleOf = (el) => {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit.split(" ")[0];
    if (el.tagName === "INPUT") {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if (type === "checkbox" || type === "radio") return type;
      if (type === "range") return "slider";
      return "textbox";
    }
    return IMPLICIT[el.tagName];
  };
  const nameOf = (el) => {
    const label = el.getAttribute("aria-label");
    if (label) return label.trim();
    const by = el.getAttribute("aria-labelledby");
    if (by)
      return by
        .split(" ")
        .map((id) => document.getElementById(id)?.textContent?.trim() ?? "")
        .join(" ")
        .trim();
    if (el.tagName === "INPUT") return (el.getAttribute("placeholder") || el.getAttribute("title") || "").trim();
    return (el.textContent || el.getAttribute("title") || "").replace(/\s+/g, " ").trim();
  };
  const unique = (selector) => {
    try {
      return document.querySelectorAll(selector).length === 1;
    } catch {
      return false;
    }
  };
  const cssPath = (el) => {
    const parts = [];
    for (let node = el; node && node.nodeType === 1 && parts.length < 6; node = node.parentElement) {
      const classes = [...node.classList].filter((name) => !/^(is-|has-|\d)/.test(name)).slice(0, 2);
      parts.unshift(node.tagName.toLowerCase() + classes.map((name) => `.${CSS.escape(name)}`).join(""));
      if (unique(parts.join(" > "))) return parts.join(" > ");
    }
    return parts.join(" > ");
  };
  /**
   * The nearest actionable ancestor's most stable description. A click needs one element; an
   * expectation (`claim`) may name several ("no Not now button is left"), so role and name stand
   * even when the page has more than one.
   */
  const targetOf = (start, claim = false) => {
    let el = start;
    for (let node = start; node && node.nodeType === 1; node = node.parentElement) {
      if (node.dataset?.testid || ROLES.has(roleOf(node) ?? "")) {
        el = node;
        break;
      }
    }
    if (el.dataset?.testid) return { testId: el.dataset.testid };
    const role = roleOf(el);
    const name = nameOf(el);
    if (role && name && name.length <= 80) {
      const same = [...document.querySelectorAll("*")].filter(
        (other) => roleOf(other) === role && nameOf(other) === name,
      );
      if (claim || same.length === 1) return { role, name, exact: true };
    }
    return { selector: cssPath(el) };
  };
  /**
   * A drag that starts within 8 px of a popup's edge is a drag of that edge (a resize), whatever
   * row the pointer is over: the popup and the edge, rather than the row and its center.
   */
  const POPUPS = new Set(["menu", "dialog", "listbox"]);
  const edgeDrag = (start, x, y) => {
    for (let node = start; node && node.nodeType === 1; node = node.parentElement) {
      if (!POPUPS.has(roleOf(node) ?? "")) continue;
      const box = node.getBoundingClientRect();
      const near = 8;
      const v = y - box.top < near ? "top" : box.bottom - y < near ? "bottom" : "";
      const h = x - box.left < near ? "left" : box.right - x < near ? "right" : "";
      if (!v && !h) return undefined;
      return { target: targetOf(node), from: v && h ? `${v}-${h}` : v || h };
    }
    return undefined;
  };
  let typing;
  const flushTyping = () => {
    if (typing) steps.push({ type: typing.text, into: typing.into });
    typing = undefined;
  };
  let press;
  addEventListener(
    "pointerdown",
    (event) => {
      if (!armed) return;
      flushTyping();
      press = {
        x: event.clientX,
        y: event.clientY,
        target: targetOf(event.target),
        edge: edgeDrag(event.target, event.clientX, event.clientY),
      };
    },
    true,
  );
  addEventListener(
    "pointerup",
    (event) => {
      if (!armed) return;
      if (!press) return;
      const dx = Math.round(event.clientX - press.x);
      const dy = Math.round(event.clientY - press.y);
      if (Math.abs(dx) + Math.abs(dy) > 4)
        steps.push(
          press.edge ? { drag: press.edge.target, dx, dy, from: press.edge.from } : { drag: press.target, dx, dy },
        );
      else steps.push({ click: press.target });
      press = undefined;
    },
    true,
  );
  addEventListener(
    "input",
    (event) => {
      if (!armed) return;
      const el = event.target;
      if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) return;
      if (el instanceof HTMLInputElement && el.type === "password") return;
      typing = { text: el.value, into: targetOf(el) };
    },
    true,
  );
  addEventListener(
    "keydown",
    (event) => {
      if (!armed) return;
      const named = ["Enter", "Escape", "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Backspace"];
      const chord = event.metaKey || event.ctrlKey || event.altKey;
      if (!named.includes(event.key) && !chord) return;
      flushTyping();
      const mods = [
        event.metaKey && "Meta",
        event.ctrlKey && "Control",
        event.altKey && "Alt",
        event.shiftKey && "Shift",
      ];
      steps.push({ press: [...mods.filter(Boolean), event.key].join("+") });
    },
    true,
  );
  window.__cmuxReview = {
    steps,
    start: () => {
      steps.length = 0;
      armed = true;
    },
    finish: () => (flushTyping(), steps.slice()),
    point: (el) => targetOf(el, true),
  };
})();
