// l10n-allow-file: public-safe gallery chat fixtures.
// Home's chat cards under the home-card-glow experiment (homeCardGlow.experiment.ts): each card a
// radial glow in its chat's own color and a tinted hairline under the meta row, brighter on hover.
// The card shell, layout, contents and actions are the same in every arm; off is the shipped look.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { GoldenLook } from "../../../gallery/golden/look";
import { DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME } from "../../../gallery/theme/ghostty";
import type { ChatCards } from "./ChatCards";
import { homeCardGlow } from "./homeCardGlow.experiment";
import type { ChatCard } from "./screenModel";

const cards: ChatCard[] = [
  {
    sessionId: "s-review",
    title: "Review the settings",
    age: "2m",
    state: "idle",
    harness: "codex",
    message: "Ready for the next step.",
  },
  { sessionId: "s-cache", title: "Tune the build cache", age: "14m", state: "running", harness: "claude" },
  { sessionId: "s-docs", title: "Update the docs", age: "3h", state: "input", harness: "claude" },
  {
    sessionId: "s-tests",
    title: "Fix the flaky test",
    age: "1d",
    state: "idle",
    harness: "codex",
    message: "The retry loop now waits on the socket, not a timer.",
  },
];
const base = { cards, onOpen: () => undefined };

/// One scheme for both of the viewer's: a light or a dark page whichever the gallery shows.
const scheme = (name: "light" | "dark"): GoldenLook => {
  const theme = { theme: name === "light" ? DEFAULT_LIGHT_THEME : DEFAULT_DARK_THEME };
  return {
    id: `home-card-glow-${name}`,
    title: name === "light" ? "Light" : "Dark",
    note: `The cards on a ${name} page.`,
    source: "agent-session/acpmux/newtab/HomeCardGlow.gallery.tsx",
    settings: {},
    schemes: { light: theme, dark: theme },
  };
};

const hoverSecond = { selector: ".nt-card-host:nth-child(2) > .nt-card" };

export default componentEntry<ComponentProps<typeof ChatCards>>({
  id: "agent-pane.home-card-glow",
  title: "Home card glow",
  area: "New Tab",
  experimental: true,
  pane: true,
  covers: [
    "agent-session/acpmux/newtab/ChatCards.tsx#ChatCards",
    "agent-session/acpmux/newtab/homeCardGlow.experiment.ts#homeCardTint",
  ],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: () => import("./ChatCards").then((module) => module.ChatCards),
  widths: { narrow: 320, normal: 620, wide: 820 },
  height: 320,
  anchors: [{ selector: ".nt-chats" }],
  experiment: {
    definition: homeCardGlow,
    script: [{ name: "hover the second card", run: (ctx) => ctx.hover(hoverSecond) }],
  },
  variants: {
    compare: { props: base, note: "The chosen arm (the compare view draws each arm here)." },
    off: { props: { ...base, glow: "off" }, note: "Off (shipped): the plain cards, unchanged." },
    subtle: { props: { ...base, glow: "subtle" }, note: "Subtle glow: each chat's own tint, faint at rest." },
    vivid: { props: { ...base, glow: "vivid" }, note: "Vivid glow: a stronger, wider tint." },
    "subtle-hover": {
      props: { ...base, glow: "subtle" },
      note: "Subtle glow, the second card hovered: its glow brightens.",
      play: (ctx) => ctx.hover(hoverSecond),
    },
    "vivid-hover": {
      props: { ...base, glow: "vivid" },
      note: "Vivid glow, the second card hovered.",
      play: (ctx) => ctx.hover(hoverSecond),
    },
    "subtle-light": {
      props: { ...base, glow: "subtle" },
      look: scheme("light"),
      note: "Subtle glow on a light page.",
    },
    "vivid-light": { props: { ...base, glow: "vivid" }, look: scheme("light"), note: "Vivid glow on a light page." },
    "subtle-dark": { props: { ...base, glow: "subtle" }, look: scheme("dark"), note: "Subtle glow on a dark page." },
    "vivid-dark": { props: { ...base, glow: "vivid" }, look: scheme("dark"), note: "Vivid glow on a dark page." },
    "off-light": { props: { ...base, glow: "off" }, look: scheme("light"), note: "Off on a light page." },
  },
});
