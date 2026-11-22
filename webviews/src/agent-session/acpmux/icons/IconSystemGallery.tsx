// l10n-allow-file: gallery fixtures, not shipped UI.
import { useId, type CSSProperties } from "react";
import { Copy, Magnifier, TerminalSquare } from "../conversation/icons";
import { Icon } from "./Icon";
import { iconLayers } from "./iconLayers";
import { bundledIconPack } from "./iconPack";

export interface IconSystemGalleryProps {
  look: "mixed-before" | "unified-after" | "heavier-comparison";
}

type Glyph = "copy" | "search" | "terminal";
const NAMES = { copy: "action.copy", search: "tool.search", terminal: "tool.shell" } as const;
const CURRENT = { copy: Copy, search: Magnifier, terminal: TerminalSquare } as const;
const SIZES = [12, 14, 16, 18, 20] as const;

/** Frozen geometry from the pre-migration transcript, used only by the before fixture. */
function BeforeTranscript({ glyph, size }: { glyph: Glyph; size: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={glyph === "copy" ? 1.25 : 1.1}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {glyph === "copy" && (
        <>
          <rect x="5.25" y="5.25" width="8.25" height="8.25" rx="2" />
          <path d="M10.75 5.25V4.5a2 2 0 0 0-2-2H4.5a2 2 0 0 0-2 2v4.25a2 2 0 0 0 2 2h.75" />
        </>
      )}
      {glyph === "search" && (
        <>
          <circle cx="7" cy="7" r="4.25" />
          <path d="M10.2 10.2 13.5 13.5" />
        </>
      )}
      {glyph === "terminal" && (
        <>
          <rect x="2.25" y="2.25" width="11.5" height="11.5" rx="2.6" />
          <path d="M5.2 6.2 7 8 5.2 9.8M8.2 10h2.6" />
        </>
      )}
    </svg>
  );
}

/** The pack's original 24-unit viewport and authored widths, before display normalization. */
function BeforePack({ glyph, size }: { glyph: Glyph; size: number }) {
  const id = useId();
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {iconLayers(bundledIconPack.icons[NAMES[glyph]].line, `before-${id}`)}
    </svg>
  );
}

function Sample({
  glyph,
  size,
  look,
  pack = false,
}: IconSystemGalleryProps & { glyph: Glyph; size: number; pack?: boolean }) {
  const Glyph = CURRENT[glyph];
  return (
    <span
      className="icon-system-sample"
      style={{ "--icon-comparison-stroke": `${(size * 1.5) / 16}px` } as CSSProperties}
    >
      {look === "mixed-before" ? (
        pack ? (
          <BeforePack glyph={glyph} size={size} />
        ) : (
          <BeforeTranscript glyph={glyph} size={size} />
        )
      ) : pack ? (
        <Icon name={NAMES[glyph]} size={size} />
      ) : (
        <Glyph size={size} />
      )}
    </span>
  );
}

export function IconSystemGallery({ look }: IconSystemGalleryProps) {
  return (
    <div className="icon-system-gallery" data-look={look}>
      <header className="icon-system-heading">
        <h2>Transcript and shared pack</h2>
        <p>Each pair: transcript · pack. The 18px column is the composer exception.</p>
      </header>
      <div className="icon-system-scales">
        {SIZES.map((size) => (
          <section className="icon-system-scale" key={size} aria-label={`${size}px icons`}>
            <h3>{size}px</h3>
            {(["copy", "search", "terminal"] as const).map((glyph) => (
              <div className="icon-system-pair" key={glyph} aria-label={glyph}>
                <Sample glyph={glyph} size={size} look={look} />
                <Sample glyph={glyph} size={size} look={look} pack />
              </div>
            ))}
          </section>
        ))}
      </div>
      <section className="icon-system-transcript" aria-label="Transcript example" data-gallery-track>
        <div className="icon-system-tool">
          <Sample glyph="search" size={16} look={look} />
          <span>Searched for the configuration</span>
        </div>
        <div className="icon-system-tool">
          <Sample glyph="terminal" size={16} look={look} />
          <span>Ran the project checks</span>
        </div>
        <p>The configuration is ready. All checks passed.</p>
        <div className="icon-system-footer" aria-label="Reply action">
          <Sample glyph="copy" size={16} look={look} />
        </div>
      </section>
    </div>
  );
}
