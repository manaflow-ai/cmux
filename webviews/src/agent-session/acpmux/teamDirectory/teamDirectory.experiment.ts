// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// History's People tab: RFD 0170's team navigator, recipient picker and Session Info links, drawn
/// from acpmux's `_acpmux/team/navigator`, `_acpmux/team/pick` and `_acpmux/team/session_info`
/// (server/team_directory.rs). Off by default; acpmux answers only while `meshRelay.teamMessaging`
/// is on (Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I
/// put in fleet wide pauses, esp when this is stuff that materially improves the app"). Gallery
/// `agent-pane.team-directory`.
export const teamDirectory = defineExperiment({
  id: "team-directory",
  title: "Team directory",
  description:
    "A People tab beside History's Costs: the team's spaces with who is here, search across people, agents, threads, RFDs and sessions, a Send to picker, and a session's linked threads and RFDs.",
  arms: {
    off: { label: "Off", description: "Shipped: History shows no People tab." },
    on: { label: "On", description: "History shows the People tab." },
  },
  defaultArm: "off",
});
