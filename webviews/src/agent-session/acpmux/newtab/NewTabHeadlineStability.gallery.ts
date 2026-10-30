// l10n-allow-file: synthetic gallery fixture, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { CWD, manySessions, noChat } from "../../../gallery/fixtures/acpmux";

export const longProjectName = "composer-layout-regression-with-a-deliberately-long-project-name";
export default agentPaneEntry({
  id: "agent-pane.new-tab-headline-stability",
  title: "New Tab headline stability",
  area: "New Tab",
  height: 560,
  covers: ["agent-session/acpmux/newtab/NewTabHeadline.tsx#NewTabHeadline"],
  variants: {
    long: {
      note: "A long synthetic project exercises the same project pick without shifting adjacent controls.",
      ready: {
        newSession: true,
        newTab: {
          layout: "b",
          kind: "agent",
          cwd: CWD,
          home: "/Users/you",
          lastAgent: "claude",
          template: "minimal",
          projects: [CWD, `/Users/you/src/${longProjectName}`],
          pageWidgets: ["greeting"],
        },
      },
      snapshot: noChat(manySessions(12)),
      play: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".nt-headline") !== null),
    },
  },
});
