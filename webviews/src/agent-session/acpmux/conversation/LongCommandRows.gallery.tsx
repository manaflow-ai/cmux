// l10n-allow-file: gallery fixture (sample shell commands and descriptions), not shipped UI.
// Long command rows keep the transcript quiet: the collapsed row shows a human description and
// background state, while the full argv is available on hover as a tooltip and on click in place.
import { useState } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

type Mode = "light" | "dark";
type RowKind = "short" | "long" | "background";
type Props = { mode: Mode; kind: RowKind };

const ROWS: Record<RowKind, { description: string; command: string; background?: boolean }> = {
  short: { description: "Check the current workspace", command: "git status --short" },
  long: {
    description: "Run the focused webview checks with the lane's environment",
    command:
      "cd ~/Projects/cmux/webviews && CMUX_DEV_BACKEND_MODE=local BUN_CONFIG_MAX_HTTP_REQUESTS=64 bun test test/agent-pane-background-tasks.test.tsx --reporter=spec",
  },
  background: {
    description: "Watch the gallery matrix while the agent continues",
    command:
      "cd ~/Projects/cmux && scripts/gallery-matrix/runner.ts --freestyle-vms 2 --entries agent-pane.background-activity --follow",
    background: true,
  },
};

function CommandRow({ kind }: { kind: RowKind }) {
  const row = ROWS[kind];
  const [open, setOpen] = useState(false);
  return (
    <details
      className="long-command-gallery__row"
      data-command-kind={kind}
      open={open}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary title={row.command} aria-label={`${row.description}${row.background ? ", background running" : ""}`}>
        <span className="long-command-gallery__dot" aria-hidden="true" />
        <span className="long-command-gallery__description">{row.description}</span>
        {row.background && <span className="long-command-gallery__badge">Background · running</span>}
        <span className="long-command-gallery__chevron" aria-hidden="true">
          {open ? "⌃" : "⌄"}
        </span>
      </summary>
      {open && (
        <div className="long-command-gallery__expanded" data-full-command>
          <code>{row.command}</code>
          <small>Full command · click the row again to collapse</small>
        </div>
      )}
    </details>
  );
}

function LongCommandRowsGallery({ mode, kind }: Props) {
  return (
    <div className="long-command-gallery" data-long-command-gallery data-mode={mode} data-kind={kind}>
      <header>
        <span className="long-command-gallery__kicker">Background commands</span>
        <h2>Quiet transcript rows</h2>
        <p>
          Collapsed rows keep the full command out of wrapping transcript text. Hover to preview it; click to expand.
        </p>
      </header>
      <CommandRow kind={kind} />
    </div>
  );
}

const inspectHoverAndClick: Play = async (ctx) => {
  const row = ctx.find({ selector: ".long-command-gallery__row" });
  const summary = row.querySelector("summary");
  if (!(summary instanceof HTMLElement) || !summary.title.includes("cd ~/Projects"))
    throw new Error("collapsed long command must expose its full command as a hover tooltip");
  await ctx.hover({ selector: ".long-command-gallery__row summary" });
  await ctx.click({ selector: ".long-command-gallery__row summary" });
  await ctx.waitFor(() => ctx.document.querySelector("[data-full-command]") !== null);
  const kind = ctx.document.querySelector("[data-long-command-gallery]")?.getAttribute("data-kind");
  const expected = kind === "background" ? "--follow" : "CMUX_DEV_BACKEND_MODE=local";
  if (!ctx.document.querySelector("[data-full-command]")?.textContent?.includes(expected))
    throw new Error("expanded row must show the full command");
};

const paired = (kind: RowKind, note: string, play?: Play): Record<string, ComponentVariant<Props>> => ({
  [`${kind}-light`]: { note: `${note} Light theme.`, props: { mode: "light", kind }, ...(play ? { play } : {}) },
  [`${kind}-dark`]: { note: `${note} Dark theme.`, props: { mode: "dark", kind }, ...(play ? { play } : {}) },
});

export default componentEntry<Props>({
  id: "agent-pane.long-command-rows",
  title: "Long command rows",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 360,
  widths: { narrow: 420, normal: 700, wide: 940 },
  anchors: [{ selector: "[data-long-command-gallery]" }],
  covers: ["agent-session/acpmux/conversation/BackgroundTaskNote.tsx#BackgroundTaskNote"],
  styles: () => import("./LongCommandRows.gallery.css"),
  load: async () => LongCommandRowsGallery,
  variants: {
    ...paired("short", "A short command fits in one quiet row with no expansion."),
    ...paired(
      "long",
      "A long multi-line command stays hidden under its description until hover or click.",
      inspectHoverAndClick,
    ),
    ...paired(
      "background",
      "A background-running row shows its badge while keeping the full command out of transcript wrapping.",
      inspectHoverAndClick,
    ),
  },
});
