// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { chat } from "../../../gallery/fixtures/acpmux";
import { ChatInspector, InspectorPanel } from "./ChatInspector";
import { DEFAULT_SECTIONS } from "./inspectorState";

function SessionInfoStability({ percent = 11 }: { percent?: number }) {
  return (
    <div className="acpmux-shell" style={{ display: "flex", justifyContent: "flex-end", height: "100%" }}>
      <InspectorPanel width={320} placement="overlay">
        <ChatInspector
          summary={{
            ...chat([]).summary!,
            cwd: "/Users/me/Projects/cmux",
            usage: { used: percent * 1000, size: 100000 },
            mcpServers: [{ name: "linear", status: "failed" }],
          }}
          machineName="Studio"
          repository="manaflow-ai/cmux"
          sections={{ ...DEFAULT_SECTIONS, context: true, connectors: true }}
          onSection={() => undefined}
          onSaveEnvironment={() => undefined}
          onReconnectMcp={() => new Promise(() => undefined)}
        />
      </InspectorPanel>
    </div>
  );
}

const changeLabels: Play = async (ctx) => {
  const saveTarget = { selector: '[data-section="environment"] button.acpmux-chat-inspector-link' };
  const reconnectTarget = { selector: '[data-section="connectors"] button.acpmux-chat-inspector-link' };
  const buttons = [ctx.find(saveTarget), ctx.find(reconnectTarget)];
  const widths = buttons.map((button) => button.getBoundingClientRect().width);
  await ctx.click(saveTarget);
  await ctx.waitFor(() => buttons[0]!.hasAttribute("disabled"));
  await ctx.click(reconnectTarget);
  await ctx.waitFor(() => buttons[1]!.hasAttribute("disabled"));
  buttons.forEach((button, index) => {
    if (Math.abs(button.getBoundingClientRect().width - widths[index]!) > 0.5) {
      throw new Error("Session Info action changed width with its label");
    }
  });
};

export default componentEntry({
  id: "agent-pane.session-info-stability",
  title: "Session Info stable values",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 320, normal: 420 },
  covers: [
    "ui/StableLabel.tsx",
    "agent-session/acpmux/inspector/EnvironmentSection.tsx",
    "agent-session/acpmux/inspector/ConnectorsSection.tsx",
    "agent-session/acpmux/inspector/ContextSection.tsx",
  ],
  load: async () => SessionInfoStability,
  variants: {
    idle: { note: "Save and Reconnect before their labels change; context uses narrow digits.", props: {} },
    changed: { note: "Saved and Reconnecting retain their original button widths.", props: {}, play: changeLabels },
    "wide-digits": { note: "The same context totals and percentages with wide digits.", props: { percent: 88 } },
  },
});
