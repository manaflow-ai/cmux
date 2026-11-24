// l10n-allow-file: gallery fixtures (sample device names, file paths and diffs), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { useT } from "../i18n";
import { CarriedSection, carriedSummary } from "./CarriedSection";
import {
  NOT_CONFIGURED,
  parseResolution,
  sampleAgentHome,
  withoutSettled,
  type AgentHome,
  type CarriedResolve,
} from "./carriedSectionModel";
import { SessionInfoPanel } from "./SessionInfo";
import { SessionInfoSection } from "./SessionInfoSection";

// A fixed clock, so the proposals' ages read the same in every capture.
const NOW = Date.UTC(2026, 10, 23, 18, 0);

type Props = { state: "off" | "carried" | "waiting"; openDiff?: boolean };

function homeFor(state: Props["state"]): AgentHome {
  if (state === "off") return NOT_CONFIGURED;
  const home = sampleAgentHome(NOW, 2);
  return state === "carried" ? { ...home, proposals: [] } : home;
}

function GalleryCarried({ state, openDiff = false }: Props) {
  const t = useT();
  const [home, setHome] = useState(() => homeFor(state));
  const [open, setOpen] = useState(state !== "off");
  // Settles as acpmux would: every named proposal it holds.
  const resolve = async ({ accept, drop }: CarriedResolve) => ({
    accepted: accept,
    dropped: drop,
    refused: [],
    revision: 15,
  });
  const summary = carriedSummary(t, home, false);
  return (
    <div className="acpmux-shell" style={{ height: "100%", display: "flex", justifyContent: "flex-end" }}>
      <SessionInfoPanel width={320} placement="overlay">
        <SessionInfoSection
          id="carried"
          title={t("rail.carried")}
          open={home.configured && open}
          onOpenChange={home.configured ? setOpen : undefined}
          meta={summary ? <span className="acpmux-session-info-section__value">{summary}</span> : undefined}
        >
          <CarriedSection
            home={home}
            onResolve={resolve}
            onSettled={(resolution) => setHome((last) => withoutSettled(last, parseResolution(resolution)))}
            locale="en"
            now={NOW}
            openDiffs={openDiff ? ["p-laptop-1\u0000CLAUDE.md"] : undefined}
          />
        </SessionInfoSection>
      </SessionInfoPanel>
    </div>
  );
}

/// The section's rows: `proposals` proposal rows and `files` carried files.
const rows =
  (proposals: number, files: number, diff: boolean): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector('[data-section="carried"]'));
    const drawn = ctx.document.querySelectorAll("[data-carried-proposal]").length;
    if (drawn !== proposals) throw new Error(`${drawn} proposals drawn, expected ${proposals}`);
    const carried = ctx.document.querySelectorAll("[data-carried-file]").length;
    if (carried !== files) throw new Error(`${carried} carried files drawn, expected ${files}`);
    if (Boolean(ctx.document.querySelector("[data-carried-diff]")) !== diff)
      throw new Error(diff ? "The diff is not open" : "A diff is open");
    if (proposals > 1 && !ctx.document.querySelector("[data-carried-batch]"))
      throw new Error("No Accept all / Drop all");
  };

export default componentEntry<Props>({
  id: "agent-pane.session-info-carried",
  title: "Session Info Carried memory",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 284, normal: 320 },
  covers: [
    "agent-session/acpmux/session-info/CarriedSection.tsx",
    "agent-session/acpmux/session-info/carriedSectionModel.ts",
    "agent-session/acpmux/session-info/sessionInfo.css",
  ],
  load: async () => GalleryCarried,
  variants: {
    "not-configured": {
      note: "Memory does not follow the person to this machine (the setting is off, or the service is not reachable): one folded line reading Off, with nothing to open.",
      props: { state: "off" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('[data-section="carried"]'));
        if (ctx.document.querySelector("[data-carried]")) throw new Error("A list drew for a machine with no head");
      },
    },
    "carried-only": {
      note: "Four files carried here and nothing waiting: the files with their kind and size; the header reads 4 files.",
      props: { state: "carried" },
      play: rows(0, 4, false),
    },
    "proposals-diff-open": {
      note: "Two proposals waiting (one from a laptop with two files, one from Cloud removing a note), the first file's diff open; Accept all and Drop all under them; the header reads 2 waiting · 4 files.",
      props: { state: "waiting", openDiff: true },
      play: rows(2, 4, true),
    },
  },
});
