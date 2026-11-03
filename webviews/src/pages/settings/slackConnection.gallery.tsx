// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { useEffect } from "react";
import { SlackConnectionRow } from "./components/SlackAccountsCard";
import type { SlackState } from "./slackConnection";
import { installCatalog } from "./strings";
import table from "./generated/strings.json";

function SlackRowGallery({ state }: { state: SlackState }) {
  installCatalog(table);
  useEffect(() => {
    const previous = document.documentElement.dataset.settingsLook;
    document.documentElement.dataset.settingsLook = "refined";
    return () => {
      if (previous === undefined) delete document.documentElement.dataset.settingsLook;
      else document.documentElement.dataset.settingsLook = previous;
    };
  }, []);
  return (
    <div className="settings" style={{ display: "block" }}>
      <main className="content">
        <div className="column">
          <div className="accounts">
            <SlackConnectionRow state={state} connect={() => {}} disconnect={() => {}} refresh={() => {}} />
          </div>
        </div>
      </main>
    </div>
  );
}
const disconnected: SlackState = { phase: "ready", teams: [], error: null, confirmed: false };
export default componentEntry<{ state: SlackState }>({
  id: "settings.slack-connection",
  title: "Slack connection",
  area: "Settings",
  height: 220,
  widths: { narrow: 360, normal: 640, wide: 900 },
  covers: ["pages/settings/components/SlackAccountsCard.tsx"],
  load: async () => SlackRowGallery,
  styles: () => import("./page.css"),
  variants: {
    disconnected: { props: { state: disconnected } },
    connecting: { props: { state: { ...disconnected, phase: "connecting" } } },
    awaiting: { props: { state: { ...disconnected, phase: "awaiting" } } },
    connected: {
      props: {
        state: {
          ...disconnected,
          teams: [{ slackTeamId: "T-example", name: "Example workspace", cmuxTeamId: "team-example" }],
        },
      },
    },
    error: { props: { state: { ...disconnected, error: "failed" } } },
  },
});
