// l10n-allow-file: gallery fixtures (a made-up run), not shipped UI.
import type { PosterData } from "./posterModel";

/// A made-up app screen as an SVG `data:` URL: a stand-in for a real before or after capture.
function screen(dark: boolean, accent: string, label: string): string {
  const bg = dark ? "#1c1f26" : "#f3f4f7";
  const panel = dark ? "#262a33" : "#ffffff";
  const line = dark ? "#3a3f4b" : "#dfe2e8";
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="420" viewBox="0 0 640 420">
<rect width="640" height="420" fill="${bg}"/>
<rect x="0" y="0" width="640" height="44" fill="${panel}"/>
<circle cx="22" cy="22" r="6" fill="#ff5f57"/><circle cx="42" cy="22" r="6" fill="#febc2e"/><circle cx="62" cy="22" r="6" fill="#28c840"/>
<rect x="24" y="68" width="160" height="328" rx="10" fill="${panel}"/>
${[0, 1, 2, 3, 4].map((i) => `<rect x="40" y="${88 + i * 34}" width="${120 - i * 12}" height="12" rx="6" fill="${line}"/>`).join("")}
<rect x="204" y="68" width="412" height="120" rx="14" fill="${accent}"/>
<text x="228" y="140" font-family="-apple-system, sans-serif" font-size="28" font-weight="700" fill="#ffffff">${label}</text>
<rect x="204" y="208" width="412" height="188" rx="14" fill="${panel}"/>
${[0, 1, 2, 3].map((i) => `<rect x="228" y="${232 + i * 36}" width="${340 - i * 40}" height="14" rx="7" fill="${line}"/>`).join("")}
</svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

export const posterRun: PosterData = {
  prompt: "Make the settings header glass like the sidebar, and keep the title from jumping when the window resizes",
  harness: "Claude Code",
  model: "Opus 5.5",
  durationMs: 252_000,
  files: 6,
  added: 214,
  removed: 38,
  hunks: [
    {
      path: "src/settings/SettingsHeader.tsx",
      lines: [
        { type: "context", text: "export function SettingsHeader({ title }: Props) {" },
        { type: "del", text: '  return <header className="settings-header solid">' },
        { type: "add", text: '  return <header className="settings-header ui-glass">' },
        { type: "add", text: "    <Title text={title} reserve={TITLE_HEIGHT} />" },
        { type: "context", text: "    <Toolbar />" },
      ],
    },
    {
      path: "src/settings/settings.css",
      lines: [
        { type: "context", text: ".settings-header {" },
        { type: "del", text: "  background: var(--surface-solid);" },
        { type: "add", text: "  background: var(--glass-fill);" },
        { type: "add", text: "  min-height: var(--header-height);" },
        { type: "context", text: "}" },
      ],
    },
    {
      path: "src/sidebar/glass.ts",
      lines: [
        { type: "add", text: "export const GLASS_BLUR = 24;" },
        { type: "add", text: "export const GLASS_SATURATE = 1.6;" },
        { type: "context", text: "" },
        { type: "context", text: "export function glassStyle(level: GlassLevel) {" },
      ],
    },
    {
      path: "src/settings/Title.tsx",
      lines: [
        { type: "context", text: "function Title({ text, reserve }: TitleProps) {" },
        { type: "add", text: "  const style = { minHeight: reserve };" },
        { type: "del", text: "  return <h1>{text}</h1>;" },
        { type: "add", text: "  return <h1 style={style}>{text}</h1>;" },
      ],
    },
  ],
  shots: {},
};

export const posterRunShots = (dark: boolean): PosterData => ({
  ...posterRun,
  shots: { before: screen(dark, "#6b7280", "Settings"), after: screen(dark, "#5b7cfa", "Settings") },
});

export const posterRunLinked: PosterData = { ...posterRun, link: "https://share.cmux.dev/v/k3J9xQ" };

export const posterRunSmall: PosterData = {
  prompt: "fix the typo in the README install line",
  harness: "Codex",
  model: "GPT-5.5",
  durationMs: 19_000,
  files: 1,
  added: 1,
  removed: 1,
  hunks: [
    {
      path: "README.md",
      lines: [
        { type: "context", text: "## Install" },
        { type: "del", text: "brew instal cmux" },
        { type: "add", text: "brew install cmux" },
      ],
    },
  ],
  shots: {},
};
