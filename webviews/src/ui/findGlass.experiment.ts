// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/** Which glass Find in Chat's pill (ChatFindBar, ui/FindPill.tsx) draws on (RFD 0207 "Web find pill on host
 * glass"; glass-raycast-parity.md "Web popups"). Settings > Advanced > Experiments > Find Glass
 * (`experiments.findGlass`, off by default) runs `host` (experiments/hostSettings.ts SETTING_ARMS); off, the
 * pill draws today's page material. The native pill (FindPillView) is the transient glass, so the host arm
 * asks for the toast role's (transient) glass at the popover level.
 * Compare in the gallery: `ui.find-pill`, variants `glass-page`, `glass-host`, `glass-host-busy`.
 * @status experimental
 */
export const findGlass = defineExperiment({
  id: "find-glass",
  title: "Find glass",
  description:
    "Which glass the find pill in a chat sits on: the page's own glass, or the App's transient glass under the page where the App draws it. Look for: legibility over busy text, and a match with the native find pill in the terminal and browser.",
  arms: {
    page: {
      label: "Page",
      description: "Today's pill: the page's own glass (what a page with no App glass under it draws).",
    },
    host: {
      label: "Host",
      description:
        "The pill marks data-host-glass (role toast, the transient glass), so the App draws its own glass under it, as under its native find pill; a page with no App glass keeps the page's glass.",
    },
  },
  defaultArm: "page",
});

export type FindGlass = keyof typeof findGlass.arms;
