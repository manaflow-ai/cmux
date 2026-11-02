// l10n-allow-file: gallery fixtures (sample harness status), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { row } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { HarnessStatusCard } from "./HarnessStatusCard";
import { ContextRing } from "./ComposerPickers";
import { ImageViewer } from "./conversation/ImageViewer";
import { SummaryCard } from "./summary/SummaryCard";

type Props = { harness: "claude" | "codex" | "opencode"; overlays?: boolean };

const details: Record<Props["harness"], { version: string; model: string; effort: string; route: string }> = {
  claude: {
    version: "2.1.309",
    model: "claude-sonnet-5-5",
    effort: "high",
    route: "sr/subrouter · sonnet-5-5",
  },
  codex: {
    version: "0.163.0",
    model: "gpt-6.1-sol",
    effort: "xhigh",
    route: "sr/subrouter · gpt-6.1-sol",
  },
  opencode: {
    version: "1.18.18",
    model: "big-pickle",
    effort: "Not reported",
    route: "local ACP route",
  },
};

// acpmux's own shape for a Claude Code chat's plan limits (claude_stdio/usage_limits.rs). The weekly
// window has no reset time, as when Claude Code does not report one. A fixed instant keeps captures stable.
const CLAUDE_USAGE_LIMITS = {
  windows: [
    { id: "session", usedPercent: 38, resetsAt: Date.UTC(2026, 9, 31, 22, 0, 0) / 1000 },
    { id: "weekly", usedPercent: 12.5 },
  ],
};

function snapshot(harness: Props["harness"]): AcpmuxSnapshot["summary"] {
  const detail = details[harness];
  return {
    sessionId: `gallery-${harness}-status`,
    cwd: "/Users/you/src/atlas-web",
    host: "build-box",
    hostKind: "cloud",
    peer: "build-box",
    harness,
    family: harness,
    model: detail.model,
    effort: detail.effort,
    usage: { used: 132_000, size: 400_000 },
    // acpmux reports limits only for Claude Code; Codex's are not mapped yet.
    ...(harness === "claude" ? { usageLimits: CLAUDE_USAGE_LIMITS } : {}),
    agentInfo: {
      version: detail.version,
      authSource: harness === "opencode" ? "environment route" : "managed login",
      routeName: detail.route,
      settingsSources: ["user", "project", "acpmux policy"],
      ...(harness === "opencode" ? { usageLimits: "Not reported by ACP" } : {}),
    },
  };
}

function GalleryStatusCard({ harness, overlays }: Props) {
  const [open, setOpen] = useState(true);
  const [imageOpen, setImageOpen] = useState(false);
  const [summaryOpen, setSummaryOpen] = useState(false);
  return (
    <div
      data-status-card-fixture
      className="acpmux-shell"
      style={{ padding: 24, height: overlays ? 560 : 360, position: "relative" }}
    >
      {open ? (
        <HarnessStatusCard
          summary={snapshot(harness)}
          rows={[row("sessionStart", 0, { sessionStart: { agent: "claude", version: details[harness].version } })]}
          onDismiss={() => setOpen(false)}
        />
      ) : (
        <div data-status-card-dismissed>Status card dismissed</div>
      )}
      {overlays && summaryOpen && (
        <SummaryCard
          rows={[]}
          subagents={{ views: undefined, current: undefined, asks: new Set(), onOpen: () => {} }}
          card={{
            shown: true,
            column: false,
            reserve: false,
            collapsed: false,
            show: () => {},
            close: () => setSummaryOpen(false),
            toggle: () => {},
            fold: () => {},
          }}
        />
      )}
      {overlays && (
        <div style={{ position: "absolute", bottom: 24, left: 24, display: "flex", gap: 12 }}>
          <button type="button" onClick={() => setImageOpen(true)}>
            Open status test image
          </button>
          <button type="button" onClick={() => setSummaryOpen(true)}>
            Open status test summary
          </button>
          <ContextRing used={100_000} size={200_000} onOpenDetails={() => undefined} />
          {imageOpen && (
            <ImageViewer
              images={[{ src: "data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=", alt: "Status test image" }]}
              index={0}
              onIndex={() => undefined}
              onClose={() => setImageOpen(false)}
            />
          )}
        </div>
      )}
    </div>
  );
}

const copyAndEscape: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Copy all" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Copied" }) !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-harness-status") === null);
};

const copyValue: Play = async (ctx) => {
  const fields = ctx.document.querySelectorAll(".acpmux-harness-status__field");
  if (fields.length !== 11) throw new Error(`Expected all 11 status rows, got ${fields.length}`);
  const value = ctx.document.querySelector<HTMLElement>(
    '[data-copy-label="Session"] .acpmux-harness-status__value-text',
  )!;
  const original = value.textContent;
  await ctx.click({ selector: '[data-copy-label="Session"]' });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector('[data-copy-label="Session"] .acpmux-harness-status__copy-feedback')?.textContent ===
      "Copied",
  );
  if (value.textContent !== original || ctx.document.defaultView?.getComputedStyle(value).userSelect !== "text")
    throw new Error("Copy feedback replaced or made the value unselectable");
};

const headerActionAlignment: Play = async (ctx) => {
  const header = ctx.document.querySelector<HTMLElement>(".acpmux-harness-status__head");
  const copy = ctx.document.querySelector<HTMLElement>(".acpmux-harness-status__copy-all");
  const close = ctx.document.querySelector<HTMLElement>(".acpmux-harness-status__close");
  const visibleCopy = copy?.querySelector<HTMLElement>('span[aria-hidden="false"]');
  if (!header || !copy || !close || !visibleCopy) throw new Error("Session status header actions are missing");
  const center = (rect: DOMRect) => rect.top + rect.height / 2;
  const actionDelta = Math.abs(center(copy.getBoundingClientRect()) - center(close.getBoundingClientRect()));
  if (actionDelta > 0.5) throw new Error(`Session status action centers differ by ${actionDelta.toFixed(2)} px`);
  const copyRange = ctx.document.createRange();
  copyRange.selectNodeContents(visibleCopy);
  const closeRange = ctx.document.createRange();
  closeRange.selectNodeContents(close);
  const textDelta = Math.abs(center(copyRange.getBoundingClientRect()) - center(closeRange.getBoundingClientRect()));
  if (textDelta > 0.5) throw new Error(`Session status action text centers differ by ${textDelta.toFixed(2)} px`);
};

const overlayPriority: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open status test image" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-image-viewer") !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-image-viewer") === null);
  if (!ctx.document.querySelector(".acpmux-harness-status")) throw new Error("Image Escape also closed status");
  await ctx.click({ selector: ".acpmux-context-ring" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-context-card[role="dialog"]') !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-card") === null);
  if (!ctx.document.querySelector(".acpmux-harness-status")) throw new Error("Context Escape also closed status");
  await ctx.click({ role: "button", name: "Open status test summary" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-summary-card[data-placement="popover"]') !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-summary-card[data-placement="popover"]') === null);
  if (!ctx.document.querySelector(".acpmux-harness-status")) throw new Error("Summary Escape also closed status");
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-harness-status") === null);
};

export default componentEntry<Props>({
  id: "agent-pane.harness-status",
  title: "Harness status card",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 420, normal: 620, wide: 760 },
  anchors: [{ selector: "[data-status-card-fixture]" }],
  covers: ["agent-session/acpmux/HarnessStatusCard.tsx#HarnessStatusCard"],
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./conversation/conversation.css"),
      import("./harnessStatus.css"),
      import("./summary/summary.css"),
    ]),
  load: async () => GalleryStatusCard,
  variants: {
    claude: {
      note: "Claude status uses the same quiet two-column card for the real harness version, route label, settings sources and the usage limits acpmux reports: each window's share used, and its reset time with time zone only when reported.",
      props: { harness: "claude" },
    },
    codex: {
      note: "Codex reports the model and xhigh effort through ACP; auth is identified by name and its value is never displayed.",
      props: { harness: "codex" },
    },
    opencode: {
      note: "OpenCode keeps unsupported effort and plan usage explicit as Not reported instead of implying zero or direct access.",
      props: { harness: "opencode" },
    },
    "copy-and-escape": {
      note: "Values remain selectable while a click copies them; Copy all uses plain label-value lines, and Escape dismisses the card.",
      props: { harness: "claude" },
      play: copyAndEscape,
    },
    "copy-value": {
      note: "A copied Session value keeps its selectable text beside a quiet Copied confirmation, with all 11 status rows intact.",
      props: { harness: "claude" },
      play: copyValue,
    },
    "header-action-alignment": {
      note: "Copy all and close share one centered action line in the Session status header.",
      props: { harness: "claude" },
      play: headerActionAlignment,
    },
    "overlay-escape-priority": {
      note: "The real image viewer, Summary popover and interactive Context ring card take Escape before Session status; the next press closes status.",
      props: { harness: "claude", overlays: true },
      height: 560,
      play: overlayPriority,
    },
  },
});
