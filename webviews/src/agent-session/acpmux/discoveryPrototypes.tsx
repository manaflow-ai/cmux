// l10n-allow-file: gallery-only prototypes for a taste pick, not shipped UI.
// Ways to find out what the composer can do without a bare "?" sheet (Leo 2026-11-22: "is there a
// /help? apparently not. welp. how should we do things?"). The real one is `/help` (HelpSheet.tsx);
// these three are disposable prototypes the composer gallery mounts from a play step, so they can
// be compared beside it: a quiet hint line under the empty prompt, the composer's keys over the box
// while the modifier is held, and a "?" in the toolbar that opens `/help`.
import { createRoot } from "react-dom/client";
import { KeyHint } from "../../ui/KeyHint";
import { COMPOSER_KEYS } from "./composerHelp";
import { translate } from "./i18n";

const dim = "var(--acpmux-composer-dim)";

function mount(host: Element, node: HTMLElement, element: React.ReactElement) {
  host.append(node);
  createRoot(node).render(element);
}

function Keys({ keys }: { keys: string }) {
  return (
    <span className="acpmux-help-keys">
      {keys.split(" ").map((key, n) => (
        <KeyHint key={n} keys={key} />
      ))}
    </span>
  );
}

/// (b) A quiet line under the empty prompt: the four things a person can type, one line, dim.
function HintLine() {
  const parts: [string, string][] = [
    ["/", "commands"],
    ["@", "files"],
    ["⌘↩", "queue"],
    ["/help", "everything"],
  ];
  return (
    <div
      data-prototype="hint-line"
      style={{
        display: "flex",
        gap: "12px",
        padding: "4px 12px 0",
        color: dim,
        fontSize: "var(--text-caption)",
        whiteSpace: "nowrap",
        overflow: "hidden",
      }}
    >
      {parts.map(([key, what]) => (
        <span key={key} style={{ display: "inline-flex", gap: "4px", alignItems: "center" }}>
          <Keys keys={key} />
          {what}
        </span>
      ))}
    </div>
  );
}

export function mountHintLine(doc: Document) {
  const box = doc.querySelector(".acpmux-composer-box");
  if (!box?.parentElement) throw new Error("no composer box");
  const node = doc.createElement("div");
  box.after(node);
  createRoot(node).render(<HintLine />);
}

/// (c) While ⌘ is held a beat: the composer's keys in two columns over the box, in the `/` list's
/// glass. Letting go hides it.
function KeyOverlay({ bottom, left, width }: { bottom: number; left: number; width: number }) {
  return (
    <div
      data-prototype="modifier-overlay"
      data-host-glass="popover"
      className="ui-popup ui-glass"
      style={{
        position: "fixed",
        bottom: `${bottom}px`,
        left: `${left}px`,
        width: `${width}px`,
        padding: "8px 12px",
        borderRadius: "12px",
        boxSizing: "border-box",
        display: "grid",
        gridTemplateColumns: "1fr 1fr",
        columnGap: "16px",
        rowGap: "4px",
        fontSize: "var(--text-control)",
      }}
    >
      {COMPOSER_KEYS.map((key) => (
        <div key={key.id} style={{ display: "flex", alignItems: "center", gap: "8px", minWidth: 0 }}>
          <Keys keys={key.keys} />
          <span
            style={{ color: "var(--agent-text)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}
          >
            {translate(key.label)}
          </span>
        </div>
      ))}
    </div>
  );
}

export function mountModifierOverlay(doc: Document) {
  const box = doc.querySelector(".acpmux-composer-box");
  if (!box) throw new Error("no composer box");
  const at = box.getBoundingClientRect();
  const view = doc.defaultView!;
  const node = doc.createElement("div");
  mount(doc.body, node, <KeyOverlay bottom={view.innerHeight - at.top + 8} left={at.left} width={at.width} />);
}

/// (d) A quiet "?" in the composer's toolbar, before the context ring, in the ring's size and ink.
/// Pressing it opens `/help`.
function HelpButton() {
  return (
    <button
      type="button"
      data-prototype="help-button"
      aria-label="Help"
      title="Commands, skills and keys (/help)"
      className="acpmux-composer-icon-button"
      style={{
        width: "24px",
        height: "24px",
        borderRadius: "999px",
        border: `1px solid ${dim}`,
        background: "none",
        color: dim,
        fontSize: "var(--text-caption)",
        fontWeight: 600,
        padding: 0,
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        cursor: "default",
      }}
    >
      ?
    </button>
  );
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
