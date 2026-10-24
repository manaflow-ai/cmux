// l10n-allow-file: gallery fixtures (drawn sample frames), not shipped UI.
// Frames for the turn reel's gallery: a browser run that signs in and opens a report, drawn as
// small SVG pages (no app or user data), plus the real sign-in screenshot the tool-images
// gallery already uses.
import { LOGIN_SCREENSHOT_PNG, LOGIN_TESTS_MP4 } from "../../../gallery/fixtures/toolImages";
import type { Play } from "../../../gallery/play";
import type { ReelFrame } from "./TurnReel";

const W = 640;
const H = 400;

/// One drawn browser page: a toolbar with its address, a heading, and the page's blocks.
function page(address: string, heading: string, blocks: string, tint = "#2b2f36"): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
<rect width="${W}" height="${H}" fill="${tint}"/>
<rect width="${W}" height="36" fill="#1d2025"/>
<circle cx="18" cy="18" r="5" fill="#ff5f57"/><circle cx="34" cy="18" r="5" fill="#febc2e"/><circle cx="50" cy="18" r="5" fill="#28c840"/>
<rect x="80" y="9" width="440" height="18" rx="9" fill="#2f333a"/>
<text x="96" y="22" font-family="-apple-system,Helvetica,sans-serif" font-size="11" fill="#aab0b8">${address}</text>
<text x="48" y="86" font-family="-apple-system,Helvetica,sans-serif" font-size="22" font-weight="600" fill="#e8eaed">${heading}</text>
${blocks}
</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const field = (y: number, text: string, focused = false) =>
  `<rect x="48" y="${y}" width="300" height="34" rx="7" fill="#1f2228" stroke="${focused ? "#8ab4f8" : "#444a52"}" stroke-width="${focused ? 2 : 1}"/>
<text x="60" y="${y + 22}" font-family="-apple-system,Helvetica,sans-serif" font-size="13" fill="#c9cdd2">${text}</text>`;
const button = (y: number, label: string, pressed = false) =>
  `<rect x="48" y="${y}" width="120" height="34" rx="7" fill="${pressed ? "#5b8def" : "#4a7bdc"}"/>
<text x="108" y="${y + 22}" text-anchor="middle" font-family="-apple-system,Helvetica,sans-serif" font-size="13" font-weight="600" fill="#fff">${label}</text>`;
const bars = (values: number[]) =>
  values
    .map(
      (value, index) =>
        `<rect x="${60 + index * 54}" y="${330 - value}" width="34" height="${value}" rx="4" fill="${index === values.length - 1 ? "#81b29a" : "#5f6b7a"}"/>`,
    )
    .join("");

const SIGN_IN = "https://atlas.example.test/sign-in";
const REPORT = "https://atlas.example.test/reports/build-times";

/** A run that signs in and opens a report: six steps, each with where it clicked or typed. */
export const BROWSER_RUN: ReelFrame[] = [
  {
    src: page(SIGN_IN, "Sign in", field(120, "Email") + field(168, "Password") + button(222, "Sign in")),
    width: W,
    height: H,
    label: "Open atlas.example.test",
    at: 1_200,
  },
  {
    src: page(
      SIGN_IN,
      "Sign in",
      field(120, "dev@example.test", true) + field(168, "Password") + button(222, "Sign in"),
    ),
    width: W,
    height: H,
    label: "Type the email",
    at: 4_800,
    click: { x: 0.31, y: 0.34 },
  },
  {
    src: page(
      SIGN_IN,
      "Sign in",
      field(120, "dev@example.test") + field(168, "••••••••", true) + button(222, "Sign in"),
    ),
    width: W,
    height: H,
    label: "Type the password",
    at: 7_100,
    click: { x: 0.31, y: 0.46 },
  },
  {
    src: page(
      SIGN_IN,
      "Sign in",
      field(120, "dev@example.test") + field(168, "••••••••") + button(222, "Sign in", true),
    ),
    width: W,
    height: H,
    label: "Click Sign in",
    at: 9_400,
    click: { x: 0.169, y: 0.6 },
  },
  {
    src: `data:image/png;base64,${LOGIN_SCREENSHOT_PNG}`,
    width: W,
    height: H,
    label: "Screenshot the dashboard",
    at: 13_900,
  },
  {
    src: page(REPORT, "Build times", bars([120, 150, 90, 170, 140, 200, 110, 60]), "#262a30"),
    width: W,
    height: H,
    label: "Open Reports › Build times",
    at: 18_300,
    click: { x: 0.62, y: 0.05 },
  },
];

/** The same run where signing in failed: the step is marked and its caption says so. */
export const FAILED_RUN: ReelFrame[] = BROWSER_RUN.slice(0, 4).map((frame, index) =>
  index === 3 ? { ...frame, label: "Click Sign in (no response after 10 s)", ok: false } : frame,
);

/** A long run (24 steps) so the strip scrolls and fades at its edges. */
export const LONG_RUN: ReelFrame[] = Array.from({ length: 24 }, (_, index) => {
  const base = BROWSER_RUN[index % BROWSER_RUN.length]!;
  return { ...base, label: `${base.label} (${index + 1})`, at: index * 2_600 };
});

/** A 16:9 desktop frame inside a reel whose stage takes the first frame's 16:10 shape. */
export const MIXED_RUN: ReelFrame[] = [
  BROWSER_RUN[0]!,
  { ...BROWSER_RUN[5]!, width: 1280, height: 720, label: "Click the Export button", click: { x: 0.9, y: 0.12 } },
];

/** A recording of a run (the tool-images gallery's 7 s MP4). */
export const RUN_RECORDING = `data:video/mp4;base64,${LOGIN_TESTS_MP4}`;

/** The interaction every turn-reel variant is measured on: focus the strip's chosen step, step
 *  back twice with the arrow key, point at another frame, then choose it. */
export const reelPlay: Play = async (ctx) => {
  await ctx.focus({ selector: ".cv-reel__thumb[aria-current='step']" });
  await ctx.press("ArrowLeft");
  await ctx.press("ArrowLeft");
  await ctx.hover({ selector: ".cv-reel__thumb:first-child" });
  await ctx.click({ selector: ".cv-reel__thumb:first-child" });
};
