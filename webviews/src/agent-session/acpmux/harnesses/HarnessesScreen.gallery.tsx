// l10n-allow-file: gallery fixtures name harnesses and commands as acpmux reports them.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxSnapshot } from "../model";
import { buildPickerCatalog, BUNDLED_MODEL_CATALOG } from "../modelCatalogData";
import { HarnessesScreen } from "./HarnessesScreen";

type Props = { acpmux: AcpmuxSnapshot["catalog"]; signedOut: string[] };

/// The page in a pane, with a host that answers `harness.health` and records what the page asks.
function GalleryHarnesses({ acpmux, signedOut }: Props) {
  const [asked, setAsked] = useState<string>();
  const [closed, setClosed] = useState(false);
  const native = (method: string, params: Record<string, unknown> = {}) => {
    if (method === "harness.health")
      return Promise.resolve({
        health: { id: params.id, auth: signedOut.includes(String(params.id)) ? "signedOut" : "signedIn" },
      });
    setAsked(`${method} ${JSON.stringify(params)}`);
    return Promise.resolve({});
  };
  return (
    <div className="acpmux-harnesses-gallery flex h-full" data-asked={asked} data-closed={closed ? "true" : "false"}>
      {closed ? null : (
        <HarnessesScreen
          catalog={buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux })}
          acpmux={acpmux}
          cwd="/Users/you/src/cmux"
          callNative={native}
          onClose={() => setClosed(true)}
        />
      )}
    </div>
  );
}

const thisMac: AcpmuxSnapshot["catalog"] = [
  { id: "claude", name: "Claude Code", family: "claude", models: [] },
  { id: "codex", name: "Codex", family: "codex", models: [], auth: { login: "codex login" } },
  { id: "grok", name: "Grok", family: "grok", models: [] },
];

const asked = (ctx: Parameters<Play>[0], prefix: string) =>
  ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-harnesses-gallery")?.getAttribute("data-asked")?.startsWith(prefix) === true,
  );

const signIn: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-harness-status="signIn"] button') !== null);
  await ctx.click({ selector: '[data-harness-status="signIn"] button' });
  await asked(ctx, 'tab.open {"kind":"terminal","text":"codex login"');
};

const custom: Play = async (ctx) => {
  await ctx.click({ selector: "[data-harness-custom]" });
  await asked(ctx, "chat.send");
};

export default componentEntry<Props>({
  id: "agent-pane.harnesses",
  title: "Harnesses page",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".acpmux-harnesses-head" }],
  covers: ["agent-session/acpmux/harnesses/HarnessesScreen.tsx#HarnessesScreen"],
  styles: () => import("../styles.css"),
  checks: {
    layoutShiftMax: {
      value: 0,
      reason: "Each harness's state arrives after the page draws; the rows keep their places.",
    },
  },
  load: async () => GalleryHarnesses,
  variants: {
    "this-mac": {
      note: "Claude Code and Grok ready, Codex signed out, the catalog's other harnesses not installed.",
      props: { acpmux: thisMac, signedOut: ["codex"] },
      play: signIn,
    },
    "custom-harness": {
      note: "Custom harness… starts the harness guide chat in this tab.",
      props: { acpmux: thisMac, signedOut: [] },
      play: custom,
    },
    "nothing-installed": {
      note: "No agent CLI on this Mac: every harness offers Install…, and Custom harness… stays.",
      props: { acpmux: [], signedOut: [] },
    },
  },
});
