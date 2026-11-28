// l10n-allow-file: gallery-only prototypes for a taste pick, not shipped UI.
// Ways to find out what the composer can do without a bare "?" sheet (Leo 2026-11-22: "is there a
// /help? apparently not. welp. how should we do things?"). The real one is `/help` (HelpSheet.tsx);
// these three are disposable prototypes the composer gallery mounts from a play step, so they can
// be compared beside it: a quiet hint line under the empty prompt, the composer's keys over the box
// while the modifier is held, and a "?" in the toolbar that opens `/help`.
import { createRoot } from "react-dom/client";
import { HelpButton, HintLine, KeyOverlay } from "./DiscoveryPrototypeViews";

function mount(host: Element, node: HTMLElement, element: React.ReactElement) {
  host.append(node);
  createRoot(node).render(element);
}

export function mountHintLine(doc: Document) {
  const box = doc.querySelector(".acpmux-composer-box");
  if (!box?.parentElement) throw new Error("no composer box");
  const node = doc.createElement("div");
  box.after(node);
  createRoot(node).render(<HintLine />);
}

export function mountModifierOverlay(doc: Document) {
  const box = doc.querySelector(".acpmux-composer-box");
  if (!box) throw new Error("no composer box");
  const at = box.getBoundingClientRect();
  const view = doc.defaultView!;
  const node = doc.createElement("div");
  mount(doc.body, node, <KeyOverlay bottom={view.innerHeight - at.top + 8} left={at.left} width={at.width} />);
}

export function mountHelpButton(doc: Document) {
  const actions = doc.querySelector(".acpmux-composer-actions");
  if (!actions) throw new Error("no composer toolbar");
  const node = doc.createElement("span");
  node.style.display = "inline-flex";
  node.style.alignItems = "center";
  const ring = actions.querySelector(".acpmux-context-ring");
  const before = ring?.closest(".acpmux-composer-actions > *") ?? actions.firstChild;
  actions.insertBefore(node, before);
  createRoot(node).render(<HelpButton />);
}
