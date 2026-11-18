// The first-user journey's eyes inside the page (run.mjs loads this through the dev server once a
// surface has loaded): it lists the controls a person could click, notes what a click changed, and
// runs rules.ts on what is shown. Every answer is plain data for the driver.
import {
  consoleErrors,
  deadButton,
  disabledWithoutReason,
  errorRegions,
  errorWithoutNextStep,
  labelOf,
  layoutBreaks,
  isSelected,
  rawErrorCodes,
  shown,
  spinners,
  type ClickEffect,
  type Red,
} from "./rules";

/// What a person can click: buttons, links, menu and list entries, tabs, switches, boxes and selects.
const CLICKABLE =
  'button, a[href], [role="button"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="option"], [role="tab"], [role="switch"], [role="checkbox"], input[type="checkbox"], input[type="radio"], select, summary';

type Counters = {
  clipboard: number;
  open: number;
  rpc: string[];
  host: string[];
  mutations: number;
};
type Win = Window & { __fujCounters?: Counters };

/// Counters the init script (run.mjs `instrument`) keeps; read here.
function counters(): Counters {
  return (window as Win).__fujCounters ?? { clipboard: 0, open: 0, rpc: [], host: [], mutations: 0 };
}

export type Control = { key: string; label: string; disabled: boolean; selected: boolean };

/// The controls under `scope` (a selector; the whole page when absent), each with a key that finds it
/// again after a re-render: its label and its place among controls of the same label.
export function controls(scope?: string): Control[] {
  const roots = scope ? [...document.querySelectorAll(scope)] : [document.body];
  const seen = new Map<string, number>();
  const found: Control[] = [];
  const nodes = new Set<Element>();
  for (const root of roots) for (const node of root.querySelectorAll(CLICKABLE)) nodes.add(node);
  for (const node of nodes) {
    // A native select stands behind its styled button (ui-select-native); the button is the control.
    if (!shown(node) || (node.tagName === "SELECT" && node.classList.contains("ui-select-native"))) continue;
    if (node.parentElement?.closest(CLICKABLE) && !node.matches('[role="option"], [role="menuitem"]')) continue;
    const label = labelOf(node);
    const index = seen.get(label) ?? 0;
    seen.set(label, index + 1);
    const disabled = (node as HTMLButtonElement).disabled || node.getAttribute("aria-disabled") === "true";
    found.push({ key: `${label}#${index}`, label, disabled, selected: isSelected(node) });
  }
  return found;
}

/// Marks the control `key` under `scope` with `data-fuj-target` for the driver's click; false when gone.
export function mark(key: string, scope?: string): boolean {
  for (const node of document.querySelectorAll("[data-fuj-target]")) node.removeAttribute("data-fuj-target");
  const roots = scope ? [...document.querySelectorAll(scope)] : [document.body];
  const seen = new Map<string, number>();
  const nodes = new Set<Element>();
  for (const root of roots) for (const node of root.querySelectorAll(CLICKABLE)) nodes.add(node);
  for (const node of nodes) {
    if (!shown(node) || (node.tagName === "SELECT" && node.classList.contains("ui-select-native"))) continue;
    if (node.parentElement?.closest(CLICKABLE) && !node.matches('[role="option"], [role="menuitem"]')) continue;
    const label = labelOf(node);
    const index = seen.get(label) ?? 0;
    seen.set(label, index + 1);
    if (`${label}#${index}` === key) {
      // An earlier click disabled it (a form opened, a row moved first): the disabled rule judges it.
      if ((node as HTMLButtonElement).disabled || node.getAttribute("aria-disabled") === "true") return false;
      node.setAttribute("data-fuj-target", "");
      return true;
    }
  }
  return false;
}

/// What a click is compared by.
export type Snapshot = {
  text: string;
  nodes: number;
  url: string;
  focus: string;
  clipboard: number;
  open: number;
  rpc: number;
  host: number;
  target: boolean;
  mutations: number;
};

export function snapshot(): Snapshot {
  const c = counters();
  const active = document.activeElement;
  return {
    text: hash(document.body.innerText),
    nodes: document.body.getElementsByTagName("*").length,
    url: location.href,
    focus: active && active !== document.body ? describePath(active) : "",
    clipboard: c.clipboard,
    open: c.open,
    rpc: c.rpc.length,
    host: c.host.length,
    target: !!document.querySelector("[data-fuj-target]"),
    mutations: c.mutations,
  };
}

/// What changed between `before` and now. Focus moving onto the clicked control itself is no effect.
export function effect(before: Snapshot, clicked: string): ClickEffect {
  const after = snapshot();
  const c = counters();
  return {
    // Attribute changes count (a switch's aria-checked, a disclosure's aria-expanded).
    dom: before.text !== after.text || before.nodes !== after.nodes || after.mutations > before.mutations,
    url: before.url !== after.url,
    focus: before.focus !== after.focus && after.focus !== clicked && after.focus !== "",
    clipboard: after.clipboard > before.clipboard,
    rpc: c.rpc.slice(before.rpc),
    host: c.host.slice(before.host),
    popup: after.open > before.open,
  };
}

/// The marked control's path, to tell focus on it from focus elsewhere.
export function targetPath(): string {
  const node = document.querySelector("[data-fuj-target]");
  return node ? describePath(node) : "";
}

/// The rules that read what is shown now (not a click): errors, raw codes, disabled controls.
export function check(ignore: readonly string[] = []): Red[] {
  const reds: Red[] = [];
  const keep = (red: Red) => !ignore.some((words) => red.detail.includes(words));
  reds.push(...errorWithoutNextStep(errorRegions(document.body)).filter(keep));
  reds.push(...rawErrorCodes(document.body).filter(keep));
  for (const node of document.querySelectorAll(CLICKABLE)) reds.push(...disabledWithoutReason(node));
  return reds;
}

/// A page with nothing left to read: the click blanked it (a crash the page did not catch).
export function blank(): boolean {
  return document.body.innerText.trim().length === 0;
}

export function loading(): string[] {
  return spinners(document.body);
}

export function layout(): Red[] {
  return layoutBreaks(document, { width: window.innerWidth, height: window.innerHeight });
}

export { consoleErrors, deadButton };

function describePath(node: Element): string {
  const parts: string[] = [];
  for (let at: Element | null = node; at && at !== document.body && parts.length < 6; at = at.parentElement) {
    const index = at.parentElement ? [...at.parentElement.children].indexOf(at) : 0;
    parts.unshift(`${at.tagName.toLowerCase()}:${index}`);
  }
  return parts.join(">");
}

function hash(text: string): string {
  let h = 0;
  for (let i = 0; i < text.length; i += 1) h = (Math.imul(31, h) + text.charCodeAt(i)) | 0;
  return `${text.length}:${h}`;
}
