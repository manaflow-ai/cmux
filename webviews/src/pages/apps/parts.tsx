// Small shared parts of the App Store page: the app icon, the host glyph, the switch, badges.
import { useState } from "react";
import { initials } from "./model";
import type { AppIconRef } from "./types";

/** The host's drawing of a cmux icon or symbol name (`glyph/<name>`, a PNG alpha mask). */
export function glyphURL(name: string): string {
  return `glyph/${encodeURIComponent(name)}`;
}

/**
 * A cmux icon drawn by the host and inked in the text color (CSS mask, so it follows the theme).
 * The host answers only cmux's own pack drawings, never an SF Symbol (coordinator Q5); when it
 * has none, `onMissing` runs and the caller draws its fallback.
 */
export function Glyph({
  name,
  size,
  className = "",
  onMissing,
}: {
  name: string;
  size: number;
  className?: string;
  onMissing?: () => void;
}) {
  const url = glyphURL(name);
  return (
    <span
      className={`apps-glyph ${className}`.trim()}
      style={{ width: size, height: size, maskImage: `url("${url}")`, WebkitMaskImage: `url("${url}")` }}
      aria-hidden="true"
    >
      {/* Only to learn whether the host has the drawing: a 404 shows the fallback. */}
      <img src={url} alt="" hidden onError={onMissing} />
    </span>
  );
}

/**
 * An app's icon: a manifest image (a data URL from the owner), else the host's drawing of the
 * manifest's symbol on a quiet tile, else the app's initials.
 */
export function AppIcon({ icon, name, size }: { icon?: AppIconRef; name: string; size: number }) {
  const [missing, setMissing] = useState(false);
  const src = icon?.path?.startsWith("data:image/") ? icon.path : undefined;
  if (src) return <img className="apps-icon" src={src} alt="" width={size} height={size} />;
  if (icon?.symbol && !missing) {
    return (
      <span className="apps-icon apps-icon-tile" style={{ width: size, height: size }} aria-hidden="true">
        <Glyph name={icon.symbol} size={Math.round(size * 0.46)} onMissing={() => setMissing(true)} />
      </span>
    );
  }
  return (
    <span
      className="apps-icon apps-icon-glyph"
      style={{ width: size, height: size, fontSize: size * 0.38 }}
      aria-hidden="true"
    >
      {initials(name)}
    </span>
  );
}

/** An on/off control (`role=switch`), Space or click toggles; no Cmd/Ctrl chords. */
export function Switch({
  on,
  label,
  disabled,
  onChange,
}: {
  on: boolean;
  label: string;
  disabled?: boolean;
  onChange: (on: boolean) => void;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      disabled={disabled}
      className={`apps-switch${on ? " on" : ""}`}
      onClick={() => onChange(!on)}
    >
      <span className="apps-switch-knob" />
    </button>
  );
}

export function Badge({ text }: { text: string }) {
  return <span className="apps-badge">{text}</span>;
}
