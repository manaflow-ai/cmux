// l10n-allow-file: gallery fixtures (sample harness status), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { row } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { HarnessStatusCard } from "./HarnessStatusCard";
import { ContextRing } from "./ComposerPickers";
import { ImageViewer } from "./conversation/ImageViewer";

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
    agentInfo: {
      version: detail.version,
      authSource: harness === "opencode" ? "environment route" : "managed login",
      routeName: detail.route,
      settingsSources: ["user", "project", "acpmux policy"],
      usageLimits: harness === "opencode" ? "Not reported by ACP" : "Weekly: 62% remaining",
    },
  };
}

function GalleryStatusCard({ harness, overlays }: Props) {
  const [open, setOpen] = useState(true);
  const [imageOpen, setImageOpen] = useState(false);
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
      {overlays && (
        <div style={{ position: "absolute", bottom: 24, left: 24, display: "flex", gap: 12 }}>
          <button type="button" onClick={() => setImageOpen(true)}>
            Open status test image
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
    Promise.all([import("./styles.css"), import("./conversation/conversation.css"), import("./harnessStatus.css")]),
  load: async () => GalleryStatusCard,
  variants: {
    claude: {
      note: "Claude status uses the same quiet two-column card for the real harness version, route label, settings sources and usage limit.",
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
    "overlay-escape-priority": {
      note: "The real image viewer and interactive Context ring card take Escape before Session status; the next press closes status.",
      props: { harness: "claude", overlays: true },
      height: 560,
      play: overlayPriority,
    },
  },
});
