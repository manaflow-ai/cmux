// l10n-allow-file: synthetic gallery fixtures (model names), not shipped UI.
import { useState, type ReactNode } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";

type Props = {
  /// `needed`: the row with Connect; `connected`: saved, before the host's list updates; `flow`: a
  /// live host whose add succeeds, so Connect opens the dialog and a valid token closes it.
  state: "needed" | "connected" | "flow";
};

const MODELS = ["Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 5.5"];

// Connect, paste a token, Verify and connect: the dialog closes and the row says Connected.
const connect: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Connect" });
  await ctx.waitFor(() => ctx.document.activeElement?.getAttribute("name") === "token");
  await ctx.type("sk-ant-oat01-0123456789abcdef");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-connect-claude-row[data-connected]") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.claude-connect-row",
  title: "Picker Claude Code Connect row",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 320, normal: 420, wide: 560 },
  covers: ["agent-session/acpmux/ClaudeConnectRow.tsx#ClaudeConnectRow"],
  load: async () => {
    const { ClaudeConnectRow, useClaudeConnectFlow } = await import("./ClaudeConnectRow");
    const { ClaudeConnectContext } = await import("./claudeConnect");
    const Section = ({ children }: { children: ReactNode }) => (
      <div className="acpmux-shell" style={{ padding: "var(--ds-space-3)" }}>
        <div
          className="ui-glass ui-glass-floats"
          style={{ borderRadius: "var(--ds-radius-popup)", padding: "var(--ds-space-1)", maxWidth: 380 }}
        >
          {children}
          {MODELS.map((model) => (
            <div key={model} className="acpmux-mp-row flex h-[28px] items-center gap-2 px-2 text-control text-fg">
              {model}
            </div>
          ))}
        </div>
      </div>
    );
    const Flow = () => {
      const { row, dialog } = useClaudeConnectFlow();
      return (
        <Section>
          {row && <ClaudeConnectRow name="Claude Code" connected={row.connected} onConnect={row.onConnect} />}
          {dialog}
        </Section>
      );
    };
    return function GalleryClaudeConnectRow({ state }: Props) {
      const [host] = useState(() => ({ needed: true, add: async () => undefined }));
      if (state === "flow")
        return (
          <ClaudeConnectContext.Provider value={host}>
            <Flow />
          </ClaudeConnectContext.Provider>
        );
      return (
        <Section>
          <ClaudeConnectRow name="Claude Code" connected={state === "connected"} onConnect={() => undefined} />
        </Section>
      );
    };
  },
  styles: () => Promise.all([import("./styles.css"), import("../../ui/ui.css"), import("../../ui/popupSurface.css")]),
  variants: {
    needed: { props: { state: "needed" } },
    connected: { props: { state: "connected" } },
    flow: { props: { state: "flow" }, play: connect },
  },
});
