// l10n-allow-file: gallery fixtures, not shipped UI.
// The illustrated empty states (Leo, 2026-10-26: "they're just gray and very sad... it's not cute.
// It's not happy."): one small Chief mascot, one plain line, one useful button, for the three empty
// cases of the NEXT web UI, each in three looks. Light and dark come from the stage.
//   no-chats (Chief Dock): ships `line-only` in its compact row. The dock draws the Chief, large,
//     right under its cards, so a second mascot there doubles it; the folded deck is 68 px tall,
//     which the row fits and the stacked look does not.
//   no-prs (GitHub page): ships `mascot-above`. A whole page, room to center the Moon over the line.
//   no-results (Messages list): ships `mascot-above`. The list column centers its empty slot already;
//     the Orb over No Results and Clear Search reads at every list width.
import mascotMochi from "../../agent-session/acpmux/mascots/ChiefMascotMochi.png";
import mascotMoon from "../../agent-session/acpmux/mascots/ChiefMascotMoon.png";
import mascotOrb from "../../agent-session/acpmux/mascots/ChiefMascotOrb.png";
import { componentEntry } from "../../gallery/format";
import type { IllustratedEmptyProps } from "./IllustratedEmpty";

const noop = () => undefined;

type Case = { art: string; line: string; label: string; lineOnlyLayout: IllustratedEmptyProps["layout"] };

const CASES: Record<"no-chats" | "no-prs" | "no-results", Case> = {
  "no-chats": { art: mascotMochi, line: "No chats yet", label: "New chat", lineOnlyLayout: "beside" },
  "no-prs": {
    art: mascotMoon,
    line: "This page shows a GitHub pull request. Open one from a chat.",
    label: "Your pull requests on GitHub",
    lineOnlyLayout: "above",
  },
  "no-results": { art: mascotOrb, line: "No Results", label: "Clear Search", lineOnlyLayout: "above" },
};

const SHIPPED: Record<keyof typeof CASES, string> = {
  "no-chats": "line-only",
  "no-prs": "mascot-above",
  "no-results": "mascot-above",
};

const variants: Record<string, { note: string; props: IllustratedEmptyProps }> = {};
for (const [name, { art, line, label, lineOnlyLayout }] of Object.entries(CASES) as [keyof typeof CASES, Case][]) {
  const action = { label, onClick: noop };
  const looks: Record<string, IllustratedEmptyProps> = {
    "mascot-above": { art, line, action, layout: "above" },
    "mascot-beside": { art, line, action, layout: "beside", artSize: 48 },
    "line-only": { line, action, layout: lineOnlyLayout },
  };
  for (const [look, props] of Object.entries(looks))
    variants[`${name}-${look}`] = {
      note: `${name}: ${look}${SHIPPED[name] === look ? " (shipped)" : ""}`,
      props,
    };
}

export default componentEntry<IllustratedEmptyProps>({
  id: "ui.illustrated-empty",
  title: "Illustrated empty state",
  area: "Pages",
  covers: ["ui/EmptyState/IllustratedEmpty.tsx#IllustratedEmpty"],
  keywords: ["empty", "no results", "no chats", "mascot", "illustration"],
  height: 240,
  load: () => import("./IllustratedEmpty").then((module) => module.IllustratedEmpty),
  variants,
});
