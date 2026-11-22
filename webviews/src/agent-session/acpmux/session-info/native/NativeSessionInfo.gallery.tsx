// l10n-allow-file: gallery-only synthetic session and native model readout.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../../gallery/format";
import { setNativeHost } from "../../native";
import { NativeSessionInfo, type NativeSessionInfoProps } from "./NativeSessionInfo";
import type { NativeSessionInfo as NativeSessionInfoModel } from "./model";

const props: NativeSessionInfoProps = {
  shown: true,
  width: 320,
  top: 0,
  side: 0,
  label: "Session Info",
  summary: {
    sessionId: "gallery-native-session-info",
    cwd: "/tmp/atlas",
    usage: { used: 100, size: 1_000 },
    mcpServers: [{ name: "github", status: "connected" }],
  },
  links: [],
  artifacts: 0,
  documents: [],
  rows: [],
  agents: [],
  waiting: new Set(),
  statuses: {},
  processes: [],
  listed: true,
  transcriptTasks: [],
  sessions: [],
  workflows: [],
};

function GalleryNativeSessionInfo() {
  const [ready, setReady] = useState(false);
  const [model, setModel] = useState<NativeSessionInfoModel>();
  useEffect(() => {
    setNativeHost(async (method, params) => {
      if (method === "pane.sessionInfo" && params.info) setModel(params.info as NativeSessionInfoModel);
      return null;
    });
    // Mount the producer only after the host can capture its first model.
    setReady(true);
    return () => setNativeHost(undefined);
  }, []);
  return (
    <div className="acpmux-shell" style={{ padding: "var(--ds-space-5)" }}>
      {ready ? <NativeSessionInfo {...props} /> : null}
      <h3>Native Session Info model</h3>
      <p>The real adapter emits these sections and rows to the app.</p>
      <pre data-testid="native-model" style={{ whiteSpace: "pre-wrap" }}>
        {model
          ? model.sections
              .map((section) =>
                [
                  `${section.id}: ${section.title}${section.meta ? ` · ${section.meta}` : ""}`,
                  ...section.rows.map((row) => `  ${row.title}${row.trailing ? ` · ${row.trailing}` : ""}`),
                ].join("\n"),
              )
              .join("\n\n")
          : "Waiting for pane.sessionInfo…"}
      </pre>
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.native-session-info-model",
  title: "Native Session Info model",
  area: "Agent pane",
  pane: true,
  height: 600,
  widths: { normal: 420 },
  covers: ["agent-session/acpmux/session-info/native/NativeSessionInfo.tsx"],
  load: async () => GalleryNativeSessionInfo,
  variants: {
    connectors: {
      note: "The real NativeSessionInfo adapter emits its synthetic GitHub connector through pane.sessionInfo; the captured model is shown as plain text.",
      props: {},
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const text = ctx.document.querySelector('[data-testid="native-model"]')?.textContent;
          return !!text?.includes("connectors:") && text.includes("github");
        });
      },
    },
  },
});
