// l10n-allow-file: synthetic gallery labels and pull requests, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { ChangesSection } from "./ChangesSection";
import { SessionInfoPanel } from "./SessionInfo";

function SessionInfoDismiss() {
  const [open, setOpen] = useState(true);
  return (
    <section className="acpmux-shell" style={{ height: "100%" }}>
      <button className="ui-button" data-outside-panel type="button" onClick={() => undefined}>
        Outside Session Info
      </button>
      {open && (
        <SessionInfoPanel width={360} placement="overlay" onDismiss={() => setOpen(false)}>
          <div className="acpmux-session-info__body">
            <ChangesSection
              statuses={{}}
              pullRequests={[
                {
                  url: "https://github.com/example/project/pull/42",
                  repo: "example/project",
                  number: 42,
                  title: "Keep nested menu dismissal in its own layer",
                  opened: true,
                  state: "open",
                },
              ]}
            />
            <button className="ui-button" data-inside-panel type="button" onClick={() => undefined}>
              Inside Session Info
            </button>
          </div>
        </SessionInfoPanel>
      )}
    </section>
  );
}

export default componentEntry({
  id: "agent-pane.session-info-dismiss",
  title: "Session Info nested menu dismissal",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 640, normal: 900 },
  covers: ["agent-session/acpmux/session-info/SessionInfo.tsx#SessionInfoPanel"],
  load: async () => SessionInfoDismiss,
  variants: {
    panel: { props: {} },
    "menu-open": {
      note: "The PR menu is portalled outside Session Info. Dismissing it leaves Session Info open.",
      props: {},
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-session-info-pr__more" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
      },
    },
  },
});
