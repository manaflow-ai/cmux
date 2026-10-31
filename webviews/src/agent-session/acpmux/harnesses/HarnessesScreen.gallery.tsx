// l10n-allow-file: gallery fixtures name harnesses and commands as acpmux reports them.
import { useMemo, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxSnapshot } from "../model";
import { buildPickerCatalog, BUNDLED_MODEL_CATALOG } from "../modelCatalogData";
import { HarnessesScreen } from "./HarnessesScreen";

type Props = {
  acpmux: AcpmuxSnapshot["catalog"];
  signedOut: string[];
  /// acpmux has not listed its harnesses yet.
  checking?: boolean;
  /// An install command run in place keeps running, or fails.
  install?: "running" | "fails";
  /// The update `harness.health` offers.
  update?: string;
};

/// The page in a pane, with a host that answers `harness.health` and `shell.*` and records what the
/// page asks.
function GalleryHarnesses({ acpmux, signedOut, checking, install, update }: Props) {
  const [asked, setAsked] = useState<string>();
  const [closed, setClosed] = useState(false);
  const reads = useRef(0);
  const native = useMemo(
    () =>
      (method: string, params: Record<string, unknown> = {}) => {
        if (method === "harness.health")
          return Promise.resolve({
            health: {
              id: params.id,
              auth: signedOut.includes(String(params.id)) ? "signedOut" : "signedIn",
              ...(update ? { update: { command: update, elevated: false } } : {}),
            },
          });
        if (method === "shell.run") return Promise.resolve({ id: "install" });
        if (method === "shell.read") {
          reads.current += 1;
          if (reads.current === 1) return Promise.resolve({ output: "added 12 packages in 4s\n", next: 1 });
          if (install === "fails")
            return Promise.resolve({
              output: "npm error code EACCES\nnpm error permission denied, mkdir '/usr/local/lib/node_modules'\n",
              next: 2,
              exit: { code: 243 },
            });
          return new Promise<never>(() => {});
        }
        setAsked(`${method} ${JSON.stringify(params)}`);
        return Promise.resolve({});
      },
    [signedOut, install, update],
  );
  return (
    <div
      className="acpmux-shell acpmux-harnesses-gallery flex h-full"
      data-asked={asked}
      data-closed={closed ? "true" : "false"}
    >
      {/* Stays drawn after it closes, so the play can read what it asked. */}
      <HarnessesScreen
        catalog={buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux })}
        acpmux={acpmux}
        cwd="/Users/you/src/cmux"
        callNative={native}
        onClose={() => setClosed(true)}
        {...(checking ? { checking } : {})}
      />
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

const installOpenCode: Play = async (ctx) => {
  await ctx.click({ selector: '[data-harness-row="opencode"] button' });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector('[data-harness-row="opencode"][data-harness-status="installing"]') !== null ||
      ctx.document.querySelector('[data-harness-row="opencode"][data-harness-status="failed"]') !== null,
  );
};

const custom: Play = async (ctx) => {
  await ctx.click({ selector: "[data-harness-custom]" });
  await asked(ctx, "chat.send");
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-harnesses-gallery[data-closed="true"]') !== null);
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
  // The agent pane's cascade: App.tsx loads the Session status card's sheet beside this page's
  // (HarnessStatusCard.tsx), so the stage does too, and a class the two share shows here as in the app.
  styles: () => Promise.all([import("../styles.css"), import("../harnessStatus.css")]),
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
    hover: {
      note: "Harness action hover states without an automatic play.",
      props: { acpmux: thisMac, signedOut: ["codex"] },
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
    checking: {
      note: "The first open after a launch, before acpmux lists its harnesses: Checking…, never Not installed.",
      props: { acpmux: [], signedOut: [], checking: true },
    },
    installing: {
      note: "Install runs OpenCode's install command in place; the row shows its last output line.",
      props: { acpmux: thisMac, signedOut: [], install: "running" },
      play: installOpenCode,
    },
    "install-failed": {
      note: "The install failed: the row says why and offers one fix, the setup guide.",
      props: { acpmux: thisMac, signedOut: [], install: "fails" },
      play: installOpenCode,
    },
    "update-offered": {
      note: "acpmux cannot run OpenCode: the row shows the first line of why and one fix, Update.",
      props: {
        acpmux: [
          ...thisMac,
          {
            id: "opencode",
            name: "OpenCode",
            family: "opencode",
            models: [],
            unavailable: "opencode 0.3.1 is too old: acpmux needs 0.4 or later\nrun opencode upgrade",
          },
        ],
        signedOut: [],
        update: "npm install -g opencode-ai@latest",
      },
    },
  },
});
