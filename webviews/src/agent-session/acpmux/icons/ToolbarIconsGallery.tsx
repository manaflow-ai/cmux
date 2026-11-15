// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState, type CSSProperties } from "react";
import { Icon } from "./Icon";

/**
 * The window's top-right tools and its sidebar toggle, as drawn on 2026-11-09 (Leo: "just draw that basketball
 * instead of that busy thing we have on our top right", a bare >_ prompt, and a toggle whose bar slides on
 * click). The toggle is native
 * (`SidebarToggleIcon.panel` in CmuxNextApp); this draws its geometry so the candidates sit side by side.
 */
export interface ToolbarIconsGalleryProps {
  toggle: "sliding-bar" | "filling-rail" | "arrow-swap";
  /** The globe and prompt before this change: one meridian curve, and the framed prompt. */
  before?: boolean;
}

const SIZES = [12, 14, 16, 20] as const;
// The sidebar's own show and hide time (Motion.sidebar, the appear and disappear tokens).
const SLIDE: CSSProperties = {
  transition: "transform var(--cmux-motion-standard) var(--cmux-ease-out), opacity var(--cmux-motion-standard)",
};

/** The panel glyph on the pack's 24-unit grid: frame 18 x 14, divider a third in. */
function ToggleGlyph({
  toggle,
  hidden,
  size,
}: {
  toggle: ToolbarIconsGalleryProps["toggle"];
  hidden: boolean;
  size: number;
}) {
  const frame = <rect x="3" y="5" width="18" height="14" rx="3.5" />;
  if (toggle === "arrow-swap") {
    return (
      <svg
        width={size}
        height={size}
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        {frame}
        <path d="M9.1 5V19" />
        {hidden ? <path d="M13 9.5L15.5 12L13 14.5" /> : <path d="M15.5 9.5L13 12L15.5 14.5" />}
      </svg>
    );
  }
  // Sliding bar: the divider at x 9.1 becomes a bar half as tall at x 6, the way the native glyph slides.
  const bar: CSSProperties = {
    ...SLIDE,
    transformBox: "fill-box",
    transformOrigin: "center",
    transform: toggle === "sliding-bar" && hidden ? "translateX(-3.1px) scaleY(0.46)" : "none",
  };
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {frame}
      {toggle === "filling-rail" && (
        <rect
          x="5"
          y="7"
          width="3.4"
          height="10"
          rx="1.2"
          fill="currentColor"
          stroke="none"
          style={{ ...SLIDE, opacity: hidden ? 0 : 1 }}
        />
      )}
      <path d="M9.1 5.75V18.25" style={bar} />
    </svg>
  );
}

function BeforeGlyph({ name, size }: { name: "browser" | "terminal"; size: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {name === "browser" ? (
        <>
          <circle cx="12" cy="12" r="8.415" />
          <path d="M3.585 12h16.83M12 3.585C9.2 6.2 8.25 9 8.25 12C8.25 15 9.2 17.8 12 20.415" />
        </>
      ) : (
        <>
          <rect x="3.846" y="4.752" width="16.308" height="14.496" rx="2.265" />
          <path d="M7.47 9.282l2.718 2.718 -2.718 2.718M12.453 14.718H16.53" />
        </>
      )}
    </svg>
  );
}

const button: CSSProperties = {
  display: "grid",
  placeItems: "center",
  width: 28,
  height: 28,
  border: 0,
  borderRadius: 8,
  background: "transparent",
  color: "var(--cmux-text-secondary, #a1a1aa)",
};

export function ToolbarIconsGallery({ toggle, before = false }: ToolbarIconsGalleryProps) {
  const [hidden, setHidden] = useState(false);
  const glyph = (name: "browser" | "terminal", size: number) =>
    before ? <BeforeGlyph name={name} size={size} /> : <Icon name={name} size={size} />;
  return (
    <div style={{ display: "grid", gap: 24, padding: 24, color: "var(--cmux-text-primary, #e4e4e7)" }}>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "4px 8px",
          borderRadius: 12,
          background: "var(--cmux-surface-raised, #1f1f23)",
        }}
      >
        <button
          type="button"
          style={button}
          aria-label={hidden ? "Show Sidebar" : "Hide Sidebar"}
          onClick={() => setHidden((value) => !value)}
        >
          <ToggleGlyph toggle={toggle} hidden={hidden} size={20} />
        </button>
        <span style={{ flex: 1, fontSize: "var(--text-caption)", opacity: 0.6 }}>
          {hidden ? "Sidebar hidden: click to show" : "Sidebar shown: click to hide"}
        </span>
        <span style={button}>{glyph("terminal", 20)}</span>
        <span style={button}>{glyph("browser", 20)}</span>
      </div>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "auto repeat(4, 28px)",
          alignItems: "center",
          gap: 12,
          fontSize: "var(--text-caption)",
        }}
      >
        <span>Globe</span>
        {SIZES.map((size) => (
          <span key={size}>{glyph("browser", size)}</span>
        ))}
        <span>Prompt</span>
        {SIZES.map((size) => (
          <span key={size}>{glyph("terminal", size)}</span>
        ))}
        <span>Toggle, shown</span>
        {SIZES.map((size) => (
          <span key={size}>
            <ToggleGlyph toggle={toggle} hidden={false} size={size} />
          </span>
        ))}
        <span>Toggle, hidden</span>
        {SIZES.map((size) => (
          <span key={size}>
            <ToggleGlyph toggle={toggle} hidden size={size} />
          </span>
        ))}
      </div>
    </div>
  );
}
