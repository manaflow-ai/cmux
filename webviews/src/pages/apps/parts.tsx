// Small shared parts of the App Store page: the app icon, the switch, badges.
import { initials } from "./model";
import type { AppIconRef } from "./types";

/**
 * An app's icon. A manifest image arrives as a data URL from the owner; a missing or SF Symbol
 * icon shows the generic glyph (no SF Symbols on the web: Apple's license; coordinator Q5).
 */
export function AppIcon({ icon, name, size }: { icon?: AppIconRef; name: string; size: number }) {
  const src = icon?.path?.startsWith("data:image/") ? icon.path : undefined;
  if (src) return <img className="apps-icon" src={src} alt="" width={size} height={size} />;
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
      title={label}
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
