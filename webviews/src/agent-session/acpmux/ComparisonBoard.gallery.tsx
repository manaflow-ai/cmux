// l10n-allow-file: gallery fixture labels are a read-only visual comparison surface.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { session } from "../../gallery/fixtures/acpmux";
import { EffortPicker } from "./EffortPicker";
import { SessionSidebar } from "./SessionSidebar";
import type { SidebarPreviewVariant } from "./sidebarPreview";

type SliderStyle = "accent" | "minimal";

type Props = {
  sliderStyle?: SliderStyle;
  previewVariant?: SidebarPreviewVariant;
  defaultSection?: "overview" | "slider" | "sidebar";
};

const efforts = [
  { id: "minimal", name: "Minimal" },
  { id: "low", name: "Low" },
  { id: "medium", name: "Medium" },
  { id: "high", name: "High", recommended: true },
  { id: "xhigh", name: "Xhigh" },
];

const sessions = [
  session({
    sessionId: "comparison-active",
    title: "Refine the checkout flow",
    updatedAt: 1_000,
    status: "running",
    indicator: "working",
    preview: "The payment form is ready for one last visual pass.",
    branch: "feat/checkout",
  }),
  session({
    sessionId: "comparison-review",
    title: "Review the sidebar polish",
    updatedAt: 900,
    unread: true,
    indicator: "done",
    preview: "Card, quiet and outline treatments are ready to compare.",
    branch: "feat/sidebar-preview",
  }),
  session({
    sessionId: "comparison-cloud",
    title: "Watch the cloud build",
    updatedAt: 800,
    host: "Build runner",
    hostKind: "cloud",
    peer: "Build runner",
    preview: "CI is running the focused gallery checks.",
    branch: "ci/nightly",
  }),
];

const openSlider: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-effort-slider") !== null);
};

const hoverSidebar: Play = async (ctx) => {
  await ctx.hover({ selector: '[data-session-id="comparison-review"]' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-preview") !== null);
};

function ComparisonBoard({ sliderStyle = "accent", previewVariant = "card", defaultSection = "overview" }: Props) {
  const [effort, setEffort] = useState("high");
  const [section, setSection] = useState<Props["defaultSection"]>(defaultSection);
  const [preview, setPreview] = useState(previewVariant);
  const showSlider = section === "overview" || section === "slider";
  const showSidebar = section === "overview" || section === "sidebar";

  return (
    <main className="cmux-comparison-board">
      <section className="cmux-comparison-window" aria-label="CMUX Next comparison board">
        <header className="cmux-comparison-titlebar">
          <div className="cmux-comparison-traffic" aria-hidden="true">
            <i className="cmux-comparison-traffic-close" />
            <i className="cmux-comparison-traffic-minimize" />
            <i className="cmux-comparison-traffic-zoom" />
          </div>
          <div className="cmux-comparison-title">CMUX Next · UI Lab</div>
          <span className="cmux-comparison-build">DEBUG PREVIEW</span>
        </header>

        <div className="cmux-comparison-toolbar">
          <div>
            <p className="cmux-comparison-eyebrow">Interactive comparison board</p>
            <h1>Composer and sidebar treatments</h1>
          </div>
          <div className="cmux-comparison-tabs" role="tablist" aria-label="Comparison sections">
            {(["overview", "slider", "sidebar"] as const).map((name) => (
              <button
                key={name}
                type="button"
                role="tab"
                aria-selected={section === name}
                className={section === name ? "is-active" : ""}
                onClick={() => setSection(name)}
              >
                {name === "overview" ? "Overview" : name === "slider" ? "Reasoning slider" : "Sidebar previews"}
              </button>
            ))}
          </div>
        </div>

        <div className="cmux-comparison-body">
          {showSidebar && (
            <aside className="cmux-comparison-sidebar" aria-label={`Sidebar preview: ${preview}`}>
              <div className="cmux-comparison-sidebar-label">Sessions · {preview}</div>
              <SessionSidebar
                sessions={sessions}
                selectedId="comparison-active"
                openIds={new Set(["comparison-review"])}
                onSelect={() => undefined}
                onNewChat={() => undefined}
                account={{ name: "Leo", detail: "Personal" }}
                preview
                previewVariant={preview}
              />
              <div className="cmux-comparison-preview-toggle" role="group" aria-label="Sidebar treatment">
                {(["card", "quiet", "outline"] as const).map((name) => (
                  <button
                    key={name}
                    type="button"
                    className={preview === name ? "is-active" : ""}
                    aria-pressed={preview === name}
                    onClick={() => setPreview(name)}
                  >
                    {name}
                  </button>
                ))}
              </div>
            </aside>
          )}

          {showSlider && (
            <div className="cmux-comparison-main">
              <div className="cmux-comparison-transcript" aria-label="Conversation preview">
                <div className="cmux-comparison-message cmux-comparison-message-user">
                  <span className="cmux-comparison-avatar">L</span>
                  <p>Can we make the composer feel a little calmer while keeping the reasoning control discoverable?</p>
                </div>
                <div className="cmux-comparison-message cmux-comparison-message-agent">
                  <span className="cmux-comparison-agent-mark">✦</span>
                  <div>
                    <p>I’m comparing the accent and minimal treatments here. Hover a session to inspect its latest reply.</p>
                    <span className="cmux-comparison-meta">Ready for review · This Mac</span>
                  </div>
                </div>
              </div>
              <div className="cmux-comparison-composer" aria-label="Composer preview">
                <div className="cmux-comparison-composer-copy">Ask anything</div>
                <div className="cmux-comparison-composer-row">
                  <span className="cmux-comparison-compose-icon" aria-hidden="true">＋</span>
                  <span className="cmux-comparison-compose-hint">Attach files or mention a project</span>
                  <div className="cmux-comparison-composer-spacer" />
                  <EffortPicker
                    label="effort"
                    efforts={efforts}
                    current={effort}
                    onPick={setEffort}
                    slider
                    sliderStyle={sliderStyle}
                  />
                  <button type="button" className="cmux-comparison-send" aria-label="Send message">↑</button>
                </div>
              </div>
              <div className="cmux-comparison-slider-toggle" role="group" aria-label="Reasoning slider treatment">
                <span>Reasoning treatment</span>
                {(["accent", "minimal"] as const).map((name) => (
                  <span key={name} className={sliderStyle === name ? "is-active" : ""}>{name}</span>
                ))}
              </div>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.comparison-board",
  title: "CMUX glass comparison board",
  area: "Agent pane",
  experimental: true,
  height: 720,
  widths: { narrow: 520, normal: 860, wide: 1160 },
  anchors: [{ selector: ".cmux-comparison-window" }],
  covers: ["agent-session/acpmux/EffortPicker.tsx#EffortPicker", "agent-session/acpmux/SessionSidebar.tsx#SessionSidebar"],
  checks: {
    anchorMovePx: { value: 0, reason: "Switching comparison sections keeps the simulated window anchored." },
    layoutShiftMax: { value: 0, reason: "Variant controls replace content inside the fixed glass shell." },
    longFrameFailMs: { value: 33, reason: "Local section and treatment toggles should remain responsive." },
  },
  load: async () => ComparisonBoard,
  styles: () =>
    Promise.all([import("./styles.css"), import("./composerControls.css"), import("./ComparisonBoard.gallery.css")]),
  variants: {
    "overview-accent-card": {
      note: "Light or dark theme: full glass shell with the accent slider and card preview treatment.",
      props: { sliderStyle: "accent", previewVariant: "card" },
      play: hoverSidebar,
    },
    "overview-minimal-quiet": {
      note: "Light or dark theme: quieter slider fill with the flatter quiet sidebar card.",
      props: { sliderStyle: "minimal", previewVariant: "quiet" },
      play: hoverSidebar,
    },
    "overview-minimal-outline": {
      note: "Light or dark theme: outlined slider thumb with the accent rim sidebar card.",
      props: { sliderStyle: "minimal", previewVariant: "outline" },
      play: hoverSidebar,
    },
    "slider-accent-open": {
      note: "Accent slider treatment mounted in the simulated composer.",
      props: { sliderStyle: "accent", previewVariant: "card", defaultSection: "slider" },
      play: openSlider,
    },
    "slider-minimal-open": {
      note: "Minimal slider treatment mounted in the simulated composer.",
      props: { sliderStyle: "minimal", previewVariant: "card", defaultSection: "slider" },
      play: openSlider,
    },
    "sidebar-card-hover": {
      note: "Card preview treatment with status and placement metadata.",
      props: { sliderStyle: "accent", previewVariant: "card", defaultSection: "sidebar" },
      play: hoverSidebar,
    },
    "sidebar-quiet-hover": {
      note: "Quiet preview treatment with less elevation and a tighter footprint.",
      props: { sliderStyle: "accent", previewVariant: "quiet", defaultSection: "sidebar" },
      play: hoverSidebar,
    },
    "sidebar-outline-hover": {
      note: "Outline preview treatment with an accent rim and no drop shadow.",
      props: { sliderStyle: "accent", previewVariant: "outline", defaultSection: "sidebar" },
      play: hoverSidebar,
    },
  },
});
