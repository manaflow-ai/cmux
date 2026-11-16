// l10n-allow-file: gallery fixtures (a sample prompt and team names), not shipped UI.
//
// "This team has no Cloud plan" (CloudStartView PlanTeamRefusal): a Cloud send the platform refused
// because the team picked in the team menu has no Cloud plan. Leo, 2026-11-09: "i guess is team? it's
// kinda hard to realize tho". The looks compare where the words go; the pane draws `notice`.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { CloudStartView } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";

const refused: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "failed",
  folder: "paint",
  code: "cloud_plan_required",
  message: "Cloud machines need a Pro plan.",
  planTeam: { team: "cmux", switchTo: { id: "team_0123456789abcdef0123", name: "Personal" } },
};
const actions = {
  onSwitchTeam: () => undefined,
  onUpgrade: () => undefined,
  onRunHere: () => undefined,
  onDismiss: () => undefined,
};

export default componentEntry<ComponentProps<typeof CloudStartView>>({
  id: "agent-pane.cloud-plan-team",
  title: "Cloud start: this team has no Cloud plan",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/CloudStartView.tsx", "agent-session/acpmux/cloudPlanTeams.ts"],
  keywords: ["cloud", "plan", "team", "switch", "upgrade", "refusal"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./CloudStartView").then((module) => module.CloudStartView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 260,
  variants: {
    notice: {
      note: "Picked. Under the message, no startup card (nothing started): the title, the team picked in the team menu, then Switch to the person's own team first, See plans, Run on This Mac and Not now.",
      props: { start: refused, ...actions },
    },
    card: {
      note: "The failed startup card stays above the same words and buttons: the checklist adds a failed machine row that explains nothing more.",
      props: { start: { ...refused, step: "machine" }, ...actions, planTeamLook: "card" },
      // The failed checklist opens on its own: the stage leaves room for it, the team line and the buttons.
      height: 560,
    },
    banner: {
      note: "The title and the buttons on one line, the team under them: tight, but the buttons wrap under the title at narrow widths.",
      props: { start: refused, ...actions, planTeamLook: "banner" },
    },
    "no-own-team": {
      note: "The team menu lists no personal team (or the device is kept to one team): See plans leads; the team is still named.",
      props: { start: { ...refused, planTeam: { team: "cmux" } }, ...actions },
    },
    "long-names": {
      note: "Long team names wrap inside their buttons' row without pushing the title.",
      height: 320,
      props: {
        start: {
          ...refused,
          planTeam: {
            team: "Manaflow Research and Platform Engineering",
            switchTo: { id: "team_0123456789abcdef0123", name: "Personal account of leo@cmux.com" },
          },
        },
        ...actions,
      },
    },
  },
});
