// l10n-allow-file: gallery fixture text, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { AppPanelSection, useAppPanelSections, type AppPanelSection as Panel } from "../../../apps/scene/panels";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { appSceneIcon } from "../../../apps/scene/SceneSymbol";
import { SessionInfoPanel } from "./SessionInfo";
import { SessionInfoSectionList } from "./SessionInfoGroup";
import { SessionInfoFold, SessionInfoSection } from "./SessionInfoSection";
import "./AppSections.gallery.css";

type Look = "plain" | "tag" | "compact";
type Props = { look?: Look };
function Slot({ panel, look }: { panel: Panel; look: Look }) {
  const [open, setOpen] = useState(true);
  const [all, setAll] = useState(false);
  if (look === "plain") return <AppPanelSection section={panel} open={open} onOpenChange={setOpen} />;
  return (
    <SessionInfoSection
      id={panel.id}
      title={panel.title}
      icon={appSceneIcon(panel.symbol)}
      open={open}
      onOpenChange={setOpen}
      meta={look === "tag" ? <span className="gallery-app-section-tag">app</span> : undefined}
    >
      <div className="gallery-app-section-content" data-cap={look === "compact" && !all ? "" : undefined}>
        {panel.node}
      </div>
      {look === "compact" && (
        <SessionInfoFold open={all} onToggle={() => setAll(!all)}>
          {all ? "Show less" : "Show all"}
        </SessionInfoFold>
      )}
    </SessionInfoSection>
  );
}
function AppSections({ look = "plain" }: Props) {
  const [client] = useState(() => new MockAppPanelsClient());
  const panels = useAppPanelSections(
    { session_id: "gallery-apps", cwd: "/projects/atlas", branch: "feature/preview", harness: "claude" },
    client,
  );
  const [more, setMore] = useState(false);
  return (
    <div className="gallery-app-sections" data-look={look}>
      <SessionInfoPanel width={340} placement="push">
        <div className="acpmux-session-info__body" data-layout="glance">
          <SessionInfoSectionList
            more={more}
            onMoreChange={setMore}
            titles={{ changes: "Changes" }}
            sections={{
              environment: (
                <SessionInfoSection id="environment" title="Environment" open bare>
                  <div className="acpmux-session-info-row">
                    <span className="acpmux-session-info-row__name">This computer</span>
                    <span className="acpmux-session-info-row__end">Local</span>
                  </div>
                </SessionInfoSection>
              ),
              context: <SessionInfoSection id="context" title="Context" icon="context.usage" open={false} meta="38%" />,
              sources: <SessionInfoSection id="sources" title="Sources" open={false} meta="3" />,
              changes: <SessionInfoSection id="changes" title="Changes" open={false} meta="2 PRs" />,
              ...Object.fromEntries(
                panels.map((panel) => [panel.id, <Slot key={panel.id} panel={panel} look={look} />]),
              ),
            }}
          />
        </div>
      </SessionInfoPanel>
    </div>
  );
}
const appsReady: Play = async (ctx) => {
  await ctx.waitFor(() => {
    const slots = ctx.document.querySelectorAll('section[data-section^="app:"]');
    return (
      slots.length === 2 && [...slots].every((slot) => slot.querySelectorAll('[data-app-type="Row"]').length === 3)
    );
  });
};

export default componentEntry<Props>({
  id: "agent-pane.session-info-app-sections",
  title: "Session Info app sections",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 360, normal: 380 },
  covers: [
    "agent-session/acpmux/session-info/SessionInfo.tsx",
    "apps/scene/SceneRenderer.tsx",
    "apps/scene/panels.tsx",
  ],
  load: async () => AppSections,
  variants: {
    plain: {
      note: "Chosen: PRs in the last 24h and Session notes use the panel's existing sections, folds and grips without another container or label. Light and dark use the gallery theme switch.",
      props: { look: "plain" },
      play: appsReady,
    },
    "with-app-tag": {
      note: "Alternative: both apps have a quiet app tag in their headers; useful attribution but repeated metadata in this small panel.",
      props: { look: "tag" },
      play: appsReady,
    },
    compact: {
      note: "Alternative: both apps cap their body at three row heights with Show all, in a compact outline. Saves space but adds two extra disclosures.",
      props: { look: "compact" },
      play: appsReady,
    },
  },
});
