// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ElevationCard } from "./ElevationCard";
import type { AcpmuxSecretAsk } from "./model";

type Props = { ask: AcpmuxSecretAsk; fails?: boolean };

const ask = (argv: string[], reason: string, timeoutSecs?: number): AcpmuxSecretAsk => ({
  secretId: "s1",
  name: "sudo",
  reason,
  elevation: { argv, host: "leos-mbp", ...(timeoutSecs ? { timeoutSecs } : {}) },
});

function GalleryElevationCard({ ask, fails }: Props) {
  return (
    <div className="acpmux-shell" data-elevation-fixture>
      <div className="acpmux-composer">
        <ElevationCard
          ask={ask}
          agent="Claude Code"
          onAnswer={(value) => (value && fails ? Promise.reject(new Error("offline")) : undefined)}
        />
      </div>
    </div>
  );
}

const typed: Play = async (ctx) => {
  await ctx.type("correct horse", { selector: ".acpmux-secret-card-field" });
  await ctx.click({ role: "button", name: "Approve" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-secret-card-field[aria-invalid=true]"));
};

export default componentEntry<Props>({
  id: "agent-pane.elevation-card",
  title: "Sudo card (request_elevation)",
  area: "Agent pane",
  height: 200,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-elevation-fixture]" }],
  covers: ["agent-session/acpmux/ElevationCard.tsx#ElevationCard"],
  styles: () => import("./styles.css"),
  load: async () => GalleryElevationCard,
  variants: {
    "fs-usage": {
      note: "A read-only diagnostic with a time limit: the exact argv, the reason, an empty field.",
      props: {
        ask: ask(
          ["fs_usage", "-w", "-f", "filesys", "-t", "10"],
          "See which process keeps writing to disk while the build stalls.",
          20,
        ),
      },
    },
    "quoted-args": {
      note: "Arguments with spaces and quotes are drawn quoted, as sudo gets them (no shell).",
      props: {
        ask: ask(
          ["launchctl", "kickstart", "-k", "system/com.apple.mDNSResponder", "it's a test"],
          "Restart DNS, as you asked, after the resolver hung.",
        ),
      },
    },
    "long-command": {
      note: "A long argv wraps inside its block; Approve stays on the field's row.",
      props: {
        ask: ask(
          [
            "log",
            "show",
            "--predicate",
            'process == "kernel" AND eventMessage CONTAINS "sandbox"',
            "--last",
            "5m",
            "--style",
            "compact",
          ],
          "Read the kernel's sandbox denials from the last five minutes.",
          120,
        ),
      },
    },
    "typed-send-failed": {
      note: "A send that failed puts the password back and marks the field.",
      props: { ask: ask(["powermetrics", "-n", "1"], "One sample of CPU power to find the hot process."), fails: true },
      play: typed,
    },
  },
});
