// l10n-allow-file: gallery fixtures (sample harness status), not shipped UI.
import { componentEntry } from "../../gallery/format";
import { row } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";
import { HarnessStatusCard } from "./HarnessStatusCard";

type Props = { harness: "claude" | "codex" | "opencode" };

const details: Record<Props["harness"], { version: string; model: string; effort: string; route: string }> = {
  claude: {
    version: "2.1.309",
    model: "claude-sonnet-5-5",
    effort: "high",
    route: "sr/subrouter · sonnet-5-5",
  },
  codex: {
    version: "0.163.0",
    model: "gpt-6.1-sol",
    effort: "xhigh",
    route: "sr/subrouter · gpt-6.1-sol",
  },
  opencode: {
    version: "1.18.18",
    model: "big-pickle",
    effort: "Not reported",
    route: "local ACP route",
  },
};

function snapshot(harness: Props["harness"]): AcpmuxSnapshot["summary"] {
  const detail = details[harness];
  return {
    sessionId: `gallery-${harness}-status`,
    cwd: "/Users/you/src/atlas-web",
    host: "build-box",
    hostKind: "cloud",
    peer: "build-box",
    harness,
    family: harness,
    model: detail.model,
    effort: detail.effort,
    usage: { used: 132_000, size: 400_000 },
    agentInfo: {
      version: detail.version,
      authSource: harness === "opencode" ? "environment route" : "managed login",
      routeName: detail.route,
      settingsSources: ["user", "project", "acpmux policy"],
      usageLimits: harness === "opencode" ? "Not reported by ACP" : "Weekly: 62% remaining",
    },
  };
}

function GalleryStatusCard({ harness }: Props) {
  return (
    <div className="acpmux-shell" style={{ padding: 24 }}>
      <HarnessStatusCard
        summary={snapshot(harness)}
        rows={[row("sessionStart", 0, { sessionStart: { agent: "claude", version: details[harness].version } })]}
        onDismiss={() => undefined}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.harness-status",
  title: "Harness status card",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 420, normal: 620, wide: 760 },
  anchors: [{ selector: ".acpmux-harness-status" }],
  covers: ["agent-session/acpmux/HarnessStatusCard.tsx#HarnessStatusCard"],
  styles: () =>
    Promise.all([import("./styles.css"), import("./conversation/conversation.css"), import("./harnessStatus.css")]),
  load: async () => GalleryStatusCard,
  variants: {
    claude: {
      note: "Claude status uses the same quiet two-column card for the real harness version, route label, settings sources and usage limit.",
      props: { harness: "claude" },
    },
    codex: {
      note: "Codex reports the model and xhigh effort through ACP; auth is identified by name and its value is never displayed.",
      props: { harness: "codex" },
    },
    opencode: {
      note: "OpenCode keeps unsupported effort and plan usage explicit as Not reported instead of implying zero or direct access.",
      props: { harness: "opencode" },
    },
  },
});
