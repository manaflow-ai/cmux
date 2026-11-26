// l10n-allow-file: gallery fixtures (sample providers and their lines), not shipped UI.
// An app connection (Settings > Integrations > Connections: Linear, Sentry, ...) drawn through the pane's
// connect card (agent-session/acpmux/ConnectCard.tsx `provider`), the card Claude and Codex use, with
// its status pill (ConnectPill.tsx) in every state: not connected, waiting for sign-in, connected,
// expiring (Reconnect before it lapses), sign in again, needs attention, unavailable and failed. The
// card's three looks (card, row, steps) are the variants.
// Leo, 2026-11-25: "are there deeper ergo things we can do wrt that? and other apps and whatnot?"
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ConnectStatus } from "./connectStatus";

type Look = "card" | "row" | "steps";
type Props = { look: Look };

type Sample = {
  status: ConnectStatus;
  title: string;
  line: string;
  label?: string;
  detail?: string;
  primary?: string;
  disconnect?: boolean;
};

const SAMPLES: Sample[] = [
  { status: "connect", title: "Linear", line: "Issues, projects and cycles.", primary: "Connect" },
  {
    status: "connecting",
    title: "GitHub",
    line: "Repositories, pull requests and issues.",
    detail: "Finish signing in in your browser. This page updates by itself.",
  },
  {
    status: "connected",
    title: "Sentry",
    line: "Errors, issues and releases.",
    label: "Connected · 14 tools",
    detail: "Personal",
    disconnect: true,
  },
  {
    status: "expiring",
    title: "Notion",
    line: "Pages, databases and comments.",
    detail: "Sign-in expires Nov 27, 9:00 AM. Reconnect to keep it working.",
    primary: "Reconnect",
    disconnect: true,
  },
  {
    status: "reauth",
    title: "Stripe",
    line: "Payments, customers and refunds.",
    detail: "Sign-in expired Nov 24, 6:00 PM. Reconnect to use it again.",
    primary: "Reconnect",
    disconnect: true,
  },
  {
    status: "attention",
    title: "Slack",
    line: "Channels, messages and threads.",
    label: "Turned off",
    primary: "Turn On",
    disconnect: true,
  },
  {
    status: "unavailable",
    title: "Figma",
    line: "Design files, comments and components.",
    detail: "Not set up on this deployment yet.",
  },
  {
    status: "error",
    title: "Exa",
    line: "Web search built for agents.",
    detail: "That didn't finish. Try again.",
    primary: "Connect",
  },
];

async function load() {
  const { Button } = await import("../../../ui/Button");
  const { ConnectCard } = await import("../../../agent-session/acpmux/ConnectCard");
  const { CONNECT_IDLE } = await import("../../../agent-session/acpmux/claudeConnect");
  const { ConnectPill } = await import("./ConnectPill");
  const { CONNECT_STATUS_KEY } = await import("./connectStatus");
  const { connectStrings } = await import("./strings");
  const strings = connectStrings();
  await import("../../settings/paneStrings");
  return function AppConnectCards({ look }: Props) {
    return (
      <section className="settings-page">
        <section className="group">
          <div className="connections-grid">
            {SAMPLES.map((sample) => (
              <div
                key={sample.status}
                className="connections-tile"
                data-connections-entry={sample.status}
                style={look === "row" ? { gridColumn: "1 / -1" } : undefined}
              >
                <ConnectCard
                  look={look}
                  progress={CONNECT_IDLE}
                  provider={{
                    mark: (
                      <span className="connections-monogram" aria-hidden="true">
                        {sample.title[0]}
                      </span>
                    ),
                    title: sample.title,
                    line: sample.line,
                    button: sample.primary ?? "",
                  }}
                  onBegin={sample.primary ? () => {} : undefined}
                  pill={
                    <ConnectPill
                      status={sample.status}
                      label={sample.label ?? strings.t(CONNECT_STATUS_KEY[sample.status])}
                    />
                  }
                  details={sample.detail ? <div className="row-help">{sample.detail}</div> : undefined}
                  extra={
                    sample.disconnect ? (
                      <Button className="button" variant="ghost" size="sm" danger>
                        Disconnect
                      </Button>
                    ) : undefined
                  }
                />
              </div>
            ))}
          </div>
        </section>
      </section>
    );
  };
}

/// Waits for the cards, so each look is captured once it drew.
const showCards: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-connect-card]"));
};

const NOTES: Record<Look, string> = {
  card: "Card (shipped in Settings): mark, name and pill on one line, the why under it, the one button below.",
  row: "Row: one compact line per connection, the pill and the one button trailing.",
  steps: "Steps: the card's layout; an app's sign-in has no numbered steps, so no caption.",
};

const variants: Record<string, { note: string; props: Props; play?: Play }> = {};
for (const look of ["card", "row", "steps"] as Look[])
  variants[look] = { note: NOTES[look], props: { look }, play: showCards };

export default componentEntry<Props>({
  id: "settings.app-connect-card",
  title: "App connect card",
  area: "Settings",
  height: 760,
  widths: { narrow: 420, normal: 860 },
  covers: ["agent-session/acpmux/ConnectCard.tsx#ConnectCard", "pages/shared/connect/ConnectPill.tsx#ConnectPill"],
  keywords: ["connect", "connection", "integration", "status", "pill", "reconnect", "expiring", "sign in again"],
  load,
  styles: () => import("../../settings/page.css"),
  variants,
});
