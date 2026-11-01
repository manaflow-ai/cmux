// l10n-allow-file: gallery-only fixture data and controls.
import { useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { chat } from "../../../gallery/fixtures/acpmux";
import { EnvironmentSection, type AccessGrant } from "./EnvironmentSection";
import { SessionInfoPanel } from "./SessionInfo";

type Props = { failFirst: boolean; granted?: boolean };
function EnvironmentSave({ failFirst, granted = false }: Props) {
  const attempts = useRef(0);
  // What the chat was granted, each with Revoke: the composer's mode menu no longer lists them.
  const [grants, setGrants] = useState<AccessGrant[]>(() =>
    granted
      ? [
          { id: "folder-trust", label: "Trusted atlas", onRemove: () => setGrants((all) => all.slice(1)) },
          { id: "chat-permission", label: "Allow for this chat", onRemove: () => setGrants((all) => all.slice(0, -1)) },
        ]
      : [],
  );
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <SessionInfoPanel width={280} placement="overlay">
        <EnvironmentSection
          summary={{ ...chat([]).summary!, cwd: "/Users/demo/Projects/atlas" }}
          machineName="Studio"
          grants={grants}
          onSave={() => {
            attempts.current++;
            if (failFirst && attempts.current === 1) return Promise.reject(new Error("Fixture host refused save"));
            return Promise.resolve();
          }}
        />
      </SessionInfoPanel>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.environment-save",
  title: "Environment save and grants",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 320, normal: 600 },
  covers: ["agent-session/acpmux/session-info/EnvironmentSection.tsx"],
  load: async () => EnvironmentSave,
  variants: {
    success: { note: "The host saves the environment.", props: { failFirst: false } },
    refused: { note: "First Save fails; the next succeeds.", props: { failFirst: true } },
    granted: {
      note: "The folder's trust and a chat-wide allowance, each with Revoke: their home since the composer's mode menu lists the modes alone (Leo, 2026-10-29).",
      props: { failFirst: false, granted: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll("li[data-grant]").length === 2);
      },
    },
    "granted-hover": {
      note: "Pointing at a grant shows its own Revoke, at once and on that row alone; the other grant's Revoke stays out of sight (still reachable with Tab).",
      props: { failFirst: false, granted: true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll("li[data-grant]").length === 2);
        await ctx.hover({ selector: 'li[data-grant="folder-trust"]' });
        await ctx.waitFor(() => {
          const shown = (id: string) =>
            ctx.document.defaultView!.getComputedStyle(ctx.document.querySelector(`li[data-grant="${id}"] > button`)!)
              .opacity;
          return shown("folder-trust") === "1" && shown("chat-permission") === "0";
        });
      },
    },
  },
});
