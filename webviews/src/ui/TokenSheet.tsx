// l10n-allow-file: the token sheet is a gallery page; its labels are token names, not shipped UI.
// The design scale on one page (gallery `ui.token-sheet`): every spacing, control, icon, radius,
// glass, elevation, colour role, type and motion token, read from the generated list
// (designTokens.generated.ts) and drawn with the live variables, so the sheet is the source.
// Colour roles show three times: the gallery's active theme, and a light and a dark terminal theme
// derived the way the app derives them (gallery/theme/web.ts), side by side.
import type { CSSProperties, ReactNode } from "react";
import { deriveAppTheme } from "../theme/appTheme";
import type { GhosttyTheme } from "../theme/ghosttyTheme";
import { themeTokens, webThemePayload } from "../gallery/theme/web";
import { cx } from "./cx";
import { COLORS, CONTROLS, ELEVATION, GLASS, ICONS, MOTION, RADII, SPACING, TEXT } from "./designTokens.generated";

const PALETTE = [
  "#1d1f21",
  "#cc6666",
  "#b5bd68",
  "#f0c674",
  "#81a2be",
  "#b294bb",
  "#8abeb7",
  "#c5c8c6",
  "#666666",
  "#d54e53",
  "#b9ca4a",
  "#e7c547",
  "#7aa6da",
  "#c397d8",
  "#70c0b1",
  "#eaeaea",
];

/** Two terminal themes the colour roles derive from: Ghostty's default dark, and its light twin. */
export const SHEET_THEMES: Record<"light" | "dark", GhosttyTheme> = {
  dark: { name: "Sheet dark", background: "#282c34", foreground: "#ffffff", palette: PALETTE },
  light: { name: "Sheet light", background: "#ffffff", foreground: "#1d1f21", palette: PALETTE },
};

/** The variables the host would send for `theme`, plus the colour roles declared again on the
 * panel: a role's var() resolves where it is declared, so the panel needs its own copy. */
export function themedPanelStyle(theme: GhosttyTheme): CSSProperties {
  const payload = webThemePayload(themeTokens(theme), deriveAppTheme(theme));
  const roles = Object.fromEntries(COLORS.map((role) => [role.variable, role.value]));
  return {
    ...payload.variables,
    ...roles,
    colorScheme: payload.colorScheme,
    background: "var(--ds-color-surface)",
    color: "var(--ds-color-fg)",
  } as CSSProperties;
}

function Section({ title, note, children }: { title: string; note?: string; children: ReactNode }) {
  return (
    <section className="ui-token-section" aria-label={title}>
      <h2 className="ui-token-title">{title}</h2>
      {note ? <p className="ui-token-note">{note}</p> : null}
      {children}
    </section>
  );
}

function Row({ name, value, children }: { name: string; value: string; children?: ReactNode }) {
  return (
    <div className="ui-token-row">
      <span className="ui-token-swatch">{children}</span>
      <code className="ui-token-name">{name}</code>
      <span className="ui-token-value">{value}</span>
    </div>
  );
}

function Colors({ label, style }: { label: string; style?: CSSProperties }) {
  return (
    <div className={cx("ui-token-colors", style && "ui-token-colors--themed")} style={style} aria-label={label}>
      <h3 className="ui-token-subtitle">{label}</h3>
      {COLORS.map((role) => (
        <Row key={role.name} name={role.variable} value={role.for}>
          <span className="ui-token-chip" style={{ background: `var(${role.variable})` }} />
        </Row>
      ))}
    </div>
  );
}

export interface TokenSheetProps {
  /** Which part to show; all by default. */
  only?: "all" | "colors";
}

export function TokenSheet({ only = "all" }: TokenSheetProps) {
  const colors = (
    <Section title="Colour roles" note="Derived from the terminal theme by the host; never literals.">
      <div className="ui-token-color-panels">
        <Colors label="Active theme" />
        <Colors label="Light" style={themedPanelStyle(SHEET_THEMES.light)} />
        <Colors label="Dark" style={themedPanelStyle(SHEET_THEMES.dark)} />
      </div>
    </Section>
  );
  if (only === "colors") return <div className="ui-token-sheet">{colors}</div>;
  return (
    <div className="ui-token-sheet">
      <Section title="Spacing" note="Tailwind's unit is the grid base: p-N is N x 4 px.">
        {SPACING.map((step) => (
          <Row key={step.variable} name={step.variable} value={`${step.px}px`}>
            <span className="ui-token-bar" style={{ width: `var(${step.variable})` }} />
          </Row>
        ))}
      </Section>
      <Section title="Control heights">
        {CONTROLS.map((control) => (
          <Row key={control.variable} name={control.variable} value={`${control.px}px, ${control.for}`}>
            <span
              className="ui-token-box"
              style={{ height: `var(${control.variable})`, width: `var(${control.variable})` }}
            />
          </Row>
        ))}
      </Section>
      <Section title="Icon sizes">
        {ICONS.map((icon) => (
          <Row key={icon.variable} name={icon.variable} value={`${icon.px}px, ${icon.for}`}>
            <span
              className="ui-token-box"
              style={{ height: `var(${icon.variable})`, width: `var(${icon.variable})` }}
            />
          </Row>
        ))}
      </Section>
      <Section title="Radii">
        {RADII.map((radius) => (
          <Row key={radius.variable} name={radius.variable} value={radius.px ? `${radius.px}px` : "menu metrics"}>
            <span className="ui-token-box ui-token-box--radius" style={{ borderRadius: `var(${radius.variable})` }} />
          </Row>
        ))}
      </Section>
      <Section title="Glass and elevation" note="Glass levels: the surface's tint over the backdrop filter.">
        <div className="ui-token-glass-stage">
          {GLASS.map((level) => (
            <div
              key={level.name}
              className="ui-token-glass"
              style={{
                background: `color-mix(in srgb, var(--glass-surface, Canvas) var(${level.tint}), transparent)`,
                backdropFilter: `var(${level.blur})`,
              }}
            >
              <strong>{level.name}</strong>
              <span>
                {level.tintPercent}%, {level.filter}
              </span>
            </div>
          ))}
        </div>
        {ELEVATION.map((elevation) => (
          <Row key={elevation.variable} name={elevation.variable} value={elevation.for}>
            <span className="ui-token-box" style={{ boxShadow: `var(${elevation.variable})` }} />
          </Row>
        ))}
      </Section>
      {colors}
      <Section title="Type">
        {TEXT.map((step) => (
          <Row key={step.variable} name={step.variable} value={`${step.px}/${step.lineHeight}, ${step.for}`}>
            <span
              style={{
                fontSize: `var(${step.variable})`,
                lineHeight: `var(${step.variable}--line-height)`,
                letterSpacing: `var(${step.variable}--letter-spacing)`,
              }}
            >
              Ag
            </span>
          </Row>
        ))}
      </Section>
      <Section title="Motion" note="One ease-out (--cmux-ease-out); Reduce Motion makes each change instant.">
        {MOTION.map((step) => (
          <Row key={step.variable} name={step.variable} value={`${step.ms}ms, ${step.for}`}>
            <span className="ui-token-bar" style={{ width: `${step.ms / 4}px` }} />
          </Row>
        ))}
      </Section>
    </div>
  );
}
