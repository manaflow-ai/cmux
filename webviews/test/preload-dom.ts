// React DOM decides once, when first loaded, whether it runs in a browser (`canUseDOM`) and
// whether `input` events drive onChange. Test files share that module, and the first one to load
// it may have no DOM yet, which would leave controlled inputs deaf to `input` events in every
// later file. Load it here with a DOM present, then remove the globals so each file sets its own.
import { JSDOM } from "jsdom";

const globals = globalThis as Record<string, unknown>;
const dom = new JSDOM("<!doctype html>");
globals.window = dom.window;
globals.document = dom.window.document;
await import("react-dom/client");
delete globals.window;
delete globals.document;
