// Installs a jsdom window (with the page stylesheet) as globals. Test files call this at the
// top level and import ./testing (React DOM) afterwards, so React sees a DOM when it loads.
import "./testCatalog";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";

export const stylesheet = readFileSync(new URL("./styles.css", import.meta.url), "utf8");

const names = [
  "window",
  "document",
  "navigator",
  "Element",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "Node",
  "Event",
  "history",
  "location",
  "scrollTo",
  "scrollX",
  "scrollY",
  "sessionStorage",
  "KeyboardEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

/** Installs a fresh jsdom (with the page stylesheet) as globals; returns the restore function. */
export function installDom(): () => void {
  const dom = new JSDOM(`<!doctype html><html><head><style>${stylesheet}</style></head><body></body></html>`, {
    url: "http://localhost/",
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
  });
  const globals = globalThis as Record<string, unknown>;
  const saved = new Map(names.map((name) => [name, globals[name]]));
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) globals[name] = win[name];
  globals.window = dom.window;
  globals.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  return () => {
    dom.window.close();
    for (const [name, value] of saved) {
      if (value === undefined) delete globals[name];
      else globals[name] = value;
    }
  };
}
