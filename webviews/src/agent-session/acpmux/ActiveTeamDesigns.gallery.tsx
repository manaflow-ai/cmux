// l10n-allow-file: gallery-only design study, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { ActiveTeamDesign } from "./ActiveTeamDesigns";

export default componentEntry<{ design: ActiveTeamDesign }>({
  id: "agent-pane.active-team-designs",
  title: "Which team is active: account menu, Switch Active Team, Cloud (designs)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/ActiveTeamDesigns.tsx#ActiveTeamDesigns", "agent-session/acpmux/TeamTag.tsx#TeamTag"],
  styles: () =>
    Promise.all([import("./styles.css"), import("./composerLocation.css"), import("./ActiveTeamDesigns.gallery.css")]),
  load: () => import("./ActiveTeamDesigns").then((module) => module.ActiveTeamDesigns),
  widths: { narrow: 420, normal: 900 },
  height: 560, // narrow stacks the menu, palette and Cloud cards: 480px measured for the list variant
  variants: {
    list: {
      note: 'Picked, and the one that ships: every team is a row of the account menu, the active one checked, a person icon for Personal and people for a team, each with a second line (Personal: the email; a team: Team and its plan). Who is signed in is a normal row that opens Accounts…, not a greyed header. Switch Active Team draws the same rows, icons and second lines, with the same checkmark in place of "Current"; the Cloud row and the Machines header name the team.',
      props: { design: "list" },
    },
    submenu: {
      note: 'One row, "Team: cmux", with the teams in a submenu. Quiet, but the other teams and Personal stay hidden behind a hover, the issue Leo hit.',
      props: { design: "submenu" },
    },
    header: {
      note: 'A native "Team" section header over the rows, no second lines. A header is drawn greyed, which is the look Leo read as "already connected"; and Personal and the duplicate team are told apart by icon only.',
      props: { design: "header" },
    },
    badge: {
      note: 'An "Active" pill beside the checked row. It says active twice and adds a control-looking pill to a menu; no second lines.',
      props: { design: "badge" },
    },
  },
});
