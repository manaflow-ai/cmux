/**
 * The "Get it on cmux" README badge (contract.md "Badge"), served at
 * `/extensions/badge.svg`. Store-badge style: a rounded rect, the cmux icon
 * and two lines of text. The text is outlined to paths (Geist, OFL) so it
 * renders the same everywhere with no web font; the SVG carries no script,
 * no external reference and no link, so GitHub's image proxy serves it as is.
 */

export type BadgeSize = "small" | "default" | "large";
export type BadgeTheme = "dark" | "light";

/** Rendered size in CSS pixels for each `?size=`; every size draws the same 122x44 artwork. */
export const BADGE_SIZES: Record<BadgeSize, { width: number; height: number }> = {
  small: { width: 100, height: 36 },
  default: { width: 122, height: 44 },
  large: { width: 166, height: 60 },
};

const VIEW_WIDTH = 122;
const VIEW_HEIGHT = 44;

/** "Get it on", Geist Regular 10px, baseline at y=0. */
const GET_IT_ON_PATH =
  "M3.62 0.16Q2.62 0.16 1.91-0.32Q1.20-0.80 0.83-1.63Q0.45-2.47 0.45-3.54Q0.45-4.61 0.83-5.45Q1.21-6.29 1.93-6.78Q2.64-7.26 3.64-7.26Q4.49-7.26 5.08-6.95Q5.66-6.64 6-6.11Q6.35-5.58 6.48-4.92L5.58-4.86Q5.45-5.55 5-5.99Q4.55-6.42 3.64-6.42Q2.83-6.42 2.33-6.02Q1.82-5.62 1.59-4.96Q1.35-4.31 1.35-3.54Q1.35-2.73 1.59-2.08Q1.83-1.44 2.34-1.06Q2.85-0.68 3.64-0.68Q4.27-0.68 4.73-0.96Q5.19-1.25 5.44-1.73Q5.69-2.21 5.70-2.77L3.66-2.77L3.66-3.59L6.50-3.59L6.50 0L5.86 0L5.82-1.19Q5.55-0.59 4.95-0.21Q4.35 0.16 3.62 0.16M9.97 0.12Q9.22 0.12 8.67-0.22Q8.13-0.56 7.84-1.18Q7.54-1.81 7.54-2.65Q7.54-3.49 7.84-4.11Q8.13-4.73 8.66-5.08Q9.20-5.42 9.93-5.42Q10.62-5.42 11.15-5.09Q11.68-4.77 11.97-4.15Q12.27-3.53 12.27-2.64L12.27-2.39L8.42-2.39Q8.47-1.54 8.88-1.11Q9.28-0.68 9.97-0.68Q10.49-0.68 10.82-0.93Q11.16-1.17 11.29-1.57L12.19-1.50Q11.98-0.79 11.39-0.33Q10.81 0.12 9.97 0.12M8.42-3.13L11.35-3.13Q11.29-3.90 10.90-4.26Q10.52-4.62 9.93-4.62Q9.32-4.62 8.92-4.25Q8.53-3.87 8.42-3.13M16.39 0L15.55 0Q14.83 0 14.48-0.33Q14.14-0.66 14.14-1.36L14.14-4.56L13.36-4.56L13.36-5.30L14.14-5.30L14.14-6.54L14.98-6.54L14.98-5.30L16.39-5.30L16.39-4.56L14.98-4.56L14.98-1.38Q14.98-1.02 15.14-0.88Q15.30-0.74 15.63-0.74L16.39-0.74M21.07 0L20.23 0L20.23-5.30L21.07-5.30L21.07 0M21.09-6.13L20.21-6.13L20.21-7.11L21.09-7.11M25.55 0L24.71 0Q23.99 0 23.64-0.33Q23.30-0.66 23.30-1.36L23.30-4.56L22.52-4.56L22.52-5.30L23.30-5.30L23.30-6.54L24.14-6.54L24.14-5.30L25.55-5.30L25.55-4.56L24.14-4.56L24.14-1.38Q24.14-1.02 24.30-0.88Q24.46-0.74 24.79-0.74L25.55-0.74M31.46 0.12Q30.73 0.12 30.18-0.22Q29.63-0.56 29.33-1.18Q29.03-1.81 29.03-2.65Q29.03-3.50 29.33-4.12Q29.63-4.74 30.18-5.08Q30.73-5.42 31.46-5.42Q32.19-5.42 32.73-5.08Q33.28-4.74 33.58-4.12Q33.88-3.50 33.88-2.65Q33.88-1.81 33.58-1.18Q33.28-0.56 32.73-0.22Q32.19 0.12 31.46 0.12M31.46-0.68Q32.19-0.68 32.59-1.21Q33-1.73 33-2.65Q33-3.57 32.59-4.09Q32.19-4.62 31.46-4.62Q30.73-4.62 30.32-4.09Q29.91-3.57 29.91-2.65Q29.91-1.73 30.32-1.21Q30.73-0.68 31.46-0.68M36.06 0L35.22 0L35.22-5.30L35.99-5.30L36.01-4.35Q36.22-4.90 36.66-5.16Q37.09-5.42 37.64-5.42Q38.25-5.42 38.65-5.15Q39.04-4.88 39.23-4.42Q39.43-3.97 39.43-3.41L39.43 0L38.59 0L38.59-3.17Q38.59-3.91 38.33-4.29Q38.06-4.68 37.46-4.68Q36.85-4.68 36.45-4.29Q36.06-3.91 36.06-3.17";

/** "cmux", Geist SemiBold 24px, baseline at y=0. */
const CMUX_PATH =
  "M7.25 0.29Q5.33 0.29 3.91-0.54Q2.50-1.37 1.72-2.88Q0.94-4.39 0.94-6.41Q0.94-8.42 1.72-9.92Q2.50-11.42 3.91-12.26Q5.33-13.10 7.25-13.10Q8.88-13.10 10.15-12.53Q11.42-11.95 12.23-10.88Q13.03-9.82 13.22-8.28L10.06-8.11Q9.86-9.34 9.11-9.97Q8.35-10.61 7.25-10.61Q5.76-10.61 4.94-9.49Q4.13-8.38 4.13-6.41Q4.13-4.42 4.94-3.31Q5.76-2.21 7.25-2.21Q8.38-2.21 9.13-2.86Q9.89-3.50 10.06-4.87L13.22-4.73Q13.03-3.19 12.24-2.06Q11.45-0.94 10.18-0.32Q8.90 0.29 7.25 0.29M18.27 0L15.20 0L15.20-12.82L17.98-12.82L18.08-9.67L17.79-9.82Q18.01-10.85 18.55-11.58Q19.09-12.31 19.87-12.71Q20.65-13.10 21.58-13.10Q23.22-13.10 24.22-12.18Q25.23-11.26 25.50-9.65L25.09-9.65Q25.30-10.78 25.83-11.53Q26.36-12.29 27.16-12.70Q27.97-13.10 28.98-13.10Q30.30-13.10 31.26-12.54Q32.22-11.98 32.73-10.90Q33.25-9.82 33.25-8.23L33.25 0L30.18 0L30.18-7.44Q30.18-9.02 29.64-9.82Q29.10-10.61 27.99-10.61Q27.25-10.61 26.72-10.22Q26.19-9.84 25.92-9.11Q25.64-8.38 25.64-7.34L25.64 0L22.78 0L22.78-7.34Q22.78-8.93 22.30-9.77Q21.82-10.61 20.65-10.61Q19.90-10.61 19.39-10.22Q18.87-9.84 18.57-9.11Q18.27-8.38 18.27-7.34M40.43 0.29Q38.49 0.29 37.35-1Q36.21-2.28 36.21-4.56L36.21-12.82L39.28-12.82L39.28-5.33Q39.28-3.72 39.82-2.96Q40.36-2.21 41.46-2.21Q42.71-2.21 43.40-3.04Q44.08-3.86 44.08-5.45L44.08-12.82L47.15-12.82L47.15 0L44.34 0L44.27-3.53L44.66-3.41Q44.37-1.58 43.29-0.65Q42.21 0.29 40.43 0.29M52.97 0L49.56 0L54.17-6.53L49.73-12.82L53.06-12.82L55.99-8.45L58.87-12.82L62.26-12.82L57.84-6.50L62.42 0L59.09 0L56.04-4.61";

/** The cmux chevron in its 256-unit icon box (public/cmux-icon.svg). */
const CHEVRON_PATH = "M91 65L179 128L91 191L91 151L139 128L91 105Z";

const THEMES: Record<BadgeTheme, { background: string; border: string; text: string; tile: string; tileBorder: string }> = {
  dark: { background: "#000", border: "#a6a6a6", text: "#fff", tile: "#fff", tileBorder: "none" },
  light: { background: "#fff", border: "#000", text: "#000", tile: "#fff", tileBorder: "#d4d4d4" },
};

export function parseBadgeSize(value: string | null | undefined): BadgeSize {
  return value === "small" || value === "large" ? value : "default";
}

export function parseBadgeTheme(value: string | null | undefined): BadgeTheme {
  return value === "light" ? "light" : "dark";
}

export function badgeSvg(options: { size?: BadgeSize; theme?: BadgeTheme } = {}): string {
  const { width, height } = BADGE_SIZES[options.size ?? "default"];
  const theme = THEMES[options.theme ?? "dark"];
  const tileStroke = theme.tileBorder === "none" ? "" : ` stroke="${theme.tileBorder}" stroke-width="8"`;
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${VIEW_WIDTH} ${VIEW_HEIGHT}" role="img" aria-label="Get it on cmux">`,
    "<title>Get it on cmux</title>",
    "<defs>",
    `<linearGradient id="cmux-badge-chevron" x1="91" y1="128" x2="179" y2="128" gradientUnits="userSpaceOnUse">`,
    `<stop offset="0" stop-color="#12c7f5"/><stop offset="0.52" stop-color="#2d8cff"/><stop offset="1" stop-color="#6c5cff"/>`,
    "</linearGradient>",
    "</defs>",
    `<rect x="0.5" y="0.5" width="${VIEW_WIDTH - 1}" height="${VIEW_HEIGHT - 1}" rx="8" fill="${theme.background}" stroke="${theme.border}"/>`,
    `<g transform="translate(8 7) scale(0.1171875)">`,
    `<rect x="4" y="4" width="248" height="248" rx="58" fill="${theme.tile}"${tileStroke}/>`,
    `<path d="${CHEVRON_PATH}" fill="url(#cmux-badge-chevron)"/>`,
    "</g>",
    `<g fill="${theme.text}">`,
    `<path transform="translate(46 17)" d="${GET_IT_ON_PATH}"/>`,
    `<path transform="translate(45.5 35)" d="${CMUX_PATH}"/>`,
    "</g>",
    "</svg>",
  ].join("");
}
