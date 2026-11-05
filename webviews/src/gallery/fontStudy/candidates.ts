// The gallery's font study (`fontStudy=<id>`, mock-app.html and frame.html): each candidate pairing of
// a face for the chrome (sidebar, tabs, titles, composer), a face for the transcript's prose, and a
// code face, rendered on the same screens so they can be judged side by side. Leo, 2026-11-05: "you
// guys never actually tested and, like, judged it, you know? I don't know what your judging quality
// or metric is, but it's, like this current version ain't it. So that's why I'm, like, you guys ought
// to be a bit more chaotic." Gallery only: these files never ship in the app. A pairing that wins
// ships through the chat's interface font choice (chatUiFont.ts), with its face bundled there.
import atkinson from "./fonts/atkinson-hyperlegible-next.woff2";
import bricolage from "./fonts/bricolage-grotesque.woff2";
import dmSans from "./fonts/dm-sans.woff2";
import figtree from "./fonts/figtree.woff2";
import fira400 from "./fonts/fira-sans-400.woff2";
import fira600 from "./fonts/fira-sans-600.woff2";
import fraunces from "./fonts/fraunces.woff2";
import geistMono from "./fonts/geist-mono.woff2";
import hanken from "./fonts/hanken-grotesk.woff2";
import plexMono from "./fonts/ibm-plex-mono-400.woff2";
import plexSerif400 from "./fonts/ibm-plex-serif-400.woff2";
import plexSerif600 from "./fonts/ibm-plex-serif-600.woff2";
import instrument from "./fonts/instrument-sans.woff2";
import jetbrains from "./fonts/jetbrains-mono.woff2";
import literata from "./fonts/literata.woff2";
import newsreader from "./fonts/newsreader.woff2";
import notoSans from "./fonts/noto-sans.woff2";
import onest from "./fonts/onest.woff2";
import publicSans from "./fonts/public-sans.woff2";
import recursive from "./fonts/recursive.woff2";
import schibsted from "./fonts/schibsted-grotesk.woff2";
import sourceSerif from "./fonts/source-serif-4.woff2";
import cmuxSansB from "./fonts/cmux-sans-b.woff2";
import cmuxSansC from "./fonts/cmux-sans-c.woff2";
import cmuxSansCG from "./fonts/cmux-sans-c-g.woff2";
import cmuxSansCL from "./fonts/cmux-sans-c-l.woff2";
import cmuxSansCLG from "./fonts/cmux-sans-c-lg.woff2";
import geist from "../../agent-session/acpmux/chatFonts/Geist-latin-wght.woff2";
import plexSans from "../../agent-session/acpmux/chatFonts/IBMPlexSans-latin-wght.woff2";
import roboto from "../../agent-session/acpmux/chatFonts/Roboto-latin-wght.woff2";
import sourceSans from "../../agent-session/acpmux/chatFonts/SourceSans3-latin-wght.woff2";

/// A face: its files, each a weight range (a variable axis) or one static weight.
type Face = { family: string; files: { url: string; weight: string }[] };
const variable = (family: string, url: string): Face => ({ family, files: [{ url, weight: "100 900" }] });

export const FACES = {
  atkinson: variable("Study Atkinson Hyperlegible Next", atkinson),
  cmuxSansB: variable("Study cmux Sans B", cmuxSansB),
  cmuxSansC: variable("Study cmux Sans C", cmuxSansC),
  cmuxSansCG: variable("Study cmux Sans C g", cmuxSansCG),
  cmuxSansCL: variable("Study cmux Sans C l", cmuxSansCL),
  cmuxSansCLG: variable("Study cmux Sans C lg", cmuxSansCLG),
  bricolage: variable("Study Bricolage Grotesque", bricolage),
  dmSans: variable("Study DM Sans", dmSans),
  figtree: variable("Study Figtree", figtree),
  fira: {
    family: "Study Fira Sans",
    files: [
      { url: fira400, weight: "400" },
      { url: fira600, weight: "600" },
    ],
  },
  fraunces: variable("Study Fraunces", fraunces),
  geist: variable("Study Geist", geist),
  geistMono: variable("Study Geist Mono", geistMono),
  hanken: variable("Study Hanken Grotesk", hanken),
  instrument: variable("Study Instrument Sans", instrument),
  jetbrains: variable("Study JetBrains Mono", jetbrains),
  literata: variable("Study Literata", literata),
  newsreader: variable("Study Newsreader", newsreader),
  notoSans: variable("Study Noto Sans", notoSans),
  onest: variable("Study Onest", onest),
  plexMono: { family: "Study IBM Plex Mono", files: [{ url: plexMono, weight: "400" }] },
  plexSans: variable("Study IBM Plex Sans", plexSans),
  plexSerif: {
    family: "Study IBM Plex Serif",
    files: [
      { url: plexSerif400, weight: "400" },
      { url: plexSerif600, weight: "600" },
    ],
  },
  publicSans: variable("Study Public Sans", publicSans),
  recursive: variable("Study Recursive", recursive),
  roboto: variable("Study Roboto", roboto),
  schibsted: variable("Study Schibsted Grotesk", schibsted),
  sourceSans: variable("Study Source Sans 3", sourceSans),
  sourceSerif: variable("Study Source Serif 4", sourceSerif),
} satisfies Record<string, Face>;
export type FaceKey = keyof typeof FACES;

/// One candidate. `ui` draws the chrome and the composer; `prose`, when set, the transcript's text
/// (else the chrome face); `mono`, when set, code (else the pane's code font). A serif prose face
/// draws a step larger, as Claude's does (its replies read at 16 px beside 14 px chrome).
export interface Pairing {
  id: string;
  label: string;
  /// Why it is a candidate, in one line.
  why: string;
  ui: FaceKey | "inter-tuned";
  prose?: FaceKey;
  mono?: FaceKey;
  proseSize?: number;
  /// Letter-spacing per type-scale step in em (caption 11 px … heading 20 px), else 0 at every step.
  tracking?: Readonly<Record<"caption" | "detail" | "body" | "field" | "title" | "heading", number>>;
}

/// cmux Sans's tracking table: open at caption and detail, where Source Sans 3's tight fit clots once the
/// x-height is raised; zero at body; tighter as the size grows to titles and headings.
const CMUX_SANS_TRACKING = { caption: 0.012, detail: 0.006, body: 0, field: -0.004, title: -0.008, heading: -0.016 };

export const PAIRINGS: readonly Pairing[] = [
  { id: "inter-tuned", label: "cmux Inter (today)", why: "Today's default, the baseline.", ui: "inter-tuned" },
  {
    id: "inter-newsreader",
    label: "Inter + Newsreader",
    why: "Today's chrome, a serif for replies as Claude pairs them.",
    ui: "inter-tuned",
    prose: "newsreader",
    proseSize: 15,
  },
  {
    id: "hanken-newsreader",
    label: "Hanken Grotesk + Newsreader",
    why: "A warm grotesque beside a text serif: the closest open pairing to Claude's sans and serif.",
    ui: "hanken",
    prose: "newsreader",
    proseSize: 15,
  },
  {
    id: "instrument-source-serif",
    label: "Instrument Sans + Source Serif 4",
    why: "A crisp grotesque with a sturdy, low-contrast text serif.",
    ui: "instrument",
    prose: "sourceSerif",
    proseSize: 15,
  },
  {
    id: "schibsted-literata",
    label: "Schibsted Grotesk + Literata",
    why: "A newspaper's grotesque and a reading-app serif, both built for screens.",
    ui: "schibsted",
    prose: "literata",
    proseSize: 15,
  },
  {
    id: "plex-superfamily",
    label: "IBM Plex Sans + Serif + Mono",
    why: "One superfamily for chrome, prose and code.",
    ui: "plexSans",
    prose: "plexSerif",
    mono: "plexMono",
    proseSize: 15,
  },
  {
    id: "instrument-fraunces",
    label: "Instrument Sans + Fraunces",
    why: "The chaotic one: a soft, wonky serif for prose.",
    ui: "instrument",
    prose: "fraunces",
    proseSize: 15,
  },
  {
    id: "geist-mono",
    label: "Geist + Geist Mono",
    why: "Vercel's grotesque and its mono, a tool's look.",
    ui: "geist",
    mono: "geistMono",
  },
  { id: "hanken", label: "Hanken Grotesk", why: "Warm, open grotesque, all sans.", ui: "hanken" },
  { id: "instrument", label: "Instrument Sans", why: "Crisp grotesque with a narrow, even rhythm.", ui: "instrument" },
  {
    id: "schibsted",
    label: "Schibsted Grotesk",
    why: "Sturdy grotesque with ink traps for small sizes.",
    ui: "schibsted",
  },
  { id: "public-sans", label: "Public Sans", why: "Neutral grotesque, near Söhne's Akzidenz roots.", ui: "publicSans" },
  {
    id: "atkinson",
    label: "Atkinson Hyperlegible Next",
    why: "Built for legibility: distinct I l 1, open shapes.",
    ui: "atkinson",
  },
  { id: "plex-sans", label: "IBM Plex Sans", why: "Engineered grotesque with humanist details.", ui: "plexSans" },
  { id: "source-sans", label: "Source Sans 3", why: "Adobe's humanist sans: calm and compact.", ui: "sourceSans" },
  {
    id: "cmux-sans-b",
    label: "cmux Sans B (+½ px, x-height +5 %)",
    why: "Source Sans 3, 4 % larger and its lowercase 5 % taller, ascenders unchanged.",
    ui: "cmuxSansB",
    tracking: CMUX_SANS_TRACKING,
  },
  {
    id: "cmux-sans-c",
    label: "cmux Sans C (x-height +8 %)",
    why: "Source Sans 3 at its own size, its lowercase 8 % taller: Inter's legibility at Source's width.",
    ui: "cmuxSansC",
    tracking: CMUX_SANS_TRACKING,
  },
  {
    id: "cmux-sans-c-l",
    label: "cmux Sans C, tailed l",
    why: "C with Source's tailed l (its ss05) as the default form: I, l and 1 apart at a glance.",
    ui: "cmuxSansCL",
    tracking: CMUX_SANS_TRACKING,
  },
  {
    id: "cmux-sans-c-g",
    label: "cmux Sans C, single-storey g",
    why: "C with Source's single-storey g (its ss04) as the default form: a rounder, quieter descender.",
    ui: "cmuxSansCG",
    tracking: CMUX_SANS_TRACKING,
  },
  {
    id: "cmux-sans-c-lg",
    label: "cmux Sans C, tailed l and single-storey g",
    why: "Both forms: the most distinct cmux Sans, still Source's own drawings.",
    ui: "cmuxSansCLG",
    tracking: CMUX_SANS_TRACKING,
  },
  { id: "fira-sans", label: "Fira Sans", why: "Mozilla's humanist sans, Meta's lineage.", ui: "fira" },
  { id: "figtree", label: "Figtree", why: "Friendly geometric with a large x-height.", ui: "figtree" },
  { id: "dm-sans", label: "DM Sans", why: "Low-contrast geometric.", ui: "dmSans" },
  { id: "onest", label: "Onest", why: "Rounded-off grotesque with Cyrillic in mind.", ui: "onest" },
  { id: "noto-sans", label: "Noto Sans", why: "The face CJK and emoji fall back next to.", ui: "notoSans" },
  { id: "roboto", label: "Roboto", why: "Android's grotesque, the familiar one.", ui: "roboto" },
  { id: "geist", label: "Geist", why: "Vercel's grotesque, all sans.", ui: "geist" },
  {
    id: "bricolage",
    label: "Bricolage Grotesque",
    why: "Chaotic: a quirky grotesque with ink traps and character.",
    ui: "bricolage",
  },
  {
    id: "recursive-jetbrains",
    label: "Recursive + JetBrains Mono",
    why: "Chaotic: a code-born sans with a coder's mono.",
    ui: "recursive",
    mono: "jetbrains",
  },
];

export const pairingById = (id: string): Pairing | undefined => PAIRINGS.find((pairing) => pairing.id === id);
