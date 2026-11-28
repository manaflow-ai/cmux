// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { TrustAsk } from "./TrustAsk";
import type { FolderTrustAsk } from "./useFolderTrustAsk";

type Props = {
  initialAsk: FolderTrustAsk;
};

const cwd = "/Users/leo/Projects/demo-app";

function ask(state: FolderTrustAsk["state"]): FolderTrustAsk {
  if (state === "decided") return { cwd, state, level: "trusted" };
  return { cwd, state };
}

function GalleryTrustAsk({ initialAsk }: Props) {
  const [current, setCurrent] = useState(initialAsk);
  const answer = (level: "trusted" | "untrusted") => setCurrent({ cwd: current.cwd, state: "decided", level });
  return (
    <div className="acpmux-shell" data-trust-fixture>
      <div className="acpmux-composer">
        <TrustAsk
          ask={current}
          agent="Codex"
          onTrust={() => answer("trusted")}
          onDistrust={() => answer("untrusted")}
          onUndo={() => setCurrent({ cwd: current.cwd, state: "ask" })}
        />
      </div>
    </div>
  );
}

const trust: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Trust" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-trust-ask-text")?.textContent === "Trusted demo-app");
};

const distrust: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Don't trust" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-trust-ask-text")?.textContent === "Won't trust demo-app");
};

const undo: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Undo" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Trust" }));
};

export default componentEntry<Props>({
  id: "agent-pane.trust-ask",
  title: "Folder trust ask",
  area: "Agent pane",
  height: 150,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-trust-fixture]" }],
  covers: ["agent-session/acpmux/TrustAsk.tsx#TrustAsk"],
  styles: () => import("./styles.css"),
  load: async () => GalleryTrustAsk,
  variants: {
    ask: { props: { initialAsk: ask("ask") }, play: trust },
    distrust: { props: { initialAsk: ask("ask") }, play: distrust },
    failed: { props: { initialAsk: ask("failed") } },
    remote: { props: { initialAsk: ask("remote") } },
    trusted: { props: { initialAsk: ask("decided") }, play: undo },
    untrusted: { props: { initialAsk: { cwd, state: "decided", level: "untrusted" } } },
  },
});
