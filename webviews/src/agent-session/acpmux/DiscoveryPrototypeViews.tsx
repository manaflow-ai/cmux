// l10n-allow-file: gallery-only prototypes for a taste pick, not shipped UI.
// The prototypes' views, which discoveryPrototypes.tsx mounts from the composer gallery's play steps.
import { COMPOSER_KEYS } from "./composerHelp";
import { translate } from "./i18n";
import { KeyHint } from "../../ui/KeyHint";

const dim = "var(--acpmux-composer-dim)";

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
export function HintLine() {
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

/// (c) While ⌘ is held a beat: the composer's keys in two columns over the box, in the `/` list's
/// glass. Letting go hides it.
export function KeyOverlay({ bottom, left, width }: { bottom: number; left: number; width: number }) {
  return (
    <div
      data-prototype="modifier-overlay"
      data-host-glass="popover"
      // Its box is fixed by the composer's measured place and width (ui/popupSettle.ts).
      data-popup-settle="own"
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

/// (d) A quiet "?" in the composer's toolbar, before the context ring, in the ring's size and ink.
/// Pressing it opens `/help`.
export function HelpButton() {
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
