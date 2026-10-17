// l10n-allow-file: gallery fixture labels are a read-only visual comparison surface.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { session } from "../../gallery/fixtures/acpmux";
import { ComposerPickers, type ComposerPermissionGrant } from "./ComposerPickers";
import { EffortTrack } from "./EffortTrack";
import { SessionPreviewCard, SessionSidebar } from "./SessionSidebar";
import { setComposerSettings } from "./composerSettings";
import type { AcpmuxSnapshot } from "./model";
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

const baseComposerSnapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "gallery",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog: [
    {
      id: "codex",
      name: "Codex",
      models: [
        {
          id: "gpt-6.1-sol",
          name: "GPT-6.1 Sol",
          efforts: ["low", "medium", "high"],
          defaultEffort: "high",
          fast: true,
          contextWindow: 200_000,
        },
      ],
    },
  ],
  summary: {
    sessionId: "comparison-composer",
    harness: "codex",
    model: "gpt-6.1-sol",
    turnCount: 1,
    usage: { used: 48_000, size: 200_000 },
    modes: {
      availableModes: [
        { id: "default", name: "Default", description: "Ask before sensitive actions." },
        { id: "full-access", name: "Full access", description: "Run actions without asking." },
        { id: "plan", name: "Plan", description: "Read and propose without editing." },
      ],
      currentModeId: "default",
    },
    configOptions: [
      {
        id: "effort",
        name: "Effort",
        category: "thought_level",
        currentValue: "high",
        options: [
          { value: "low", name: "Low" },
          { value: "medium", name: "Medium" },
          { value: "high", name: "High" },
        ],
      },
      {
        id: "fast-mode",
        name: "Fast mode",
        currentValue: "off",
        options: [
          { value: "off", name: "Off" },
          { value: "on", name: "On" },
        ],
      },
    ],
  },
};

const openSlider: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-effort-slider") !== null);
};

const hoverSidebar: Play = async (ctx) => {
  await ctx.hover({ selector: '[data-session-id="comparison-review"]' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-preview") !== null);
};

function ComparisonBoard({ sliderStyle = "accent", previewVariant = "card", defaultSection = "overview" }: Props) {
  useEffect(() => {
    // The board opts the real ComposerPickers into the same Debug Settings slider that the app uses.
    setComposerSettings({ reasoningSlider: true, reasoningSliderStyle: sliderStyle });
    return () => setComposerSettings({ reasoningSlider: false });
  }, [sliderStyle]);
  const [effort, setEffort] = useState("high");
  const [model, setModel] = useState("gpt-6.1-sol");
  const [mode, setMode] = useState("default");
  const [fast, setFast] = useState("off");
  const [grants, setGrants] = useState<ComposerPermissionGrant[]>([
    { id: "folder", label: "Trusted cmux-tui", onRemove: () => setGrants((current) => current.slice(1)) },
  ]);
  const [section, setSection] = useState<Props["defaultSection"]>(defaultSection);
  const [preview, setPreview] = useState(previewVariant);
  const [previewAnchor, setPreviewAnchor] = useState<HTMLElement | null>(null);
  const showSlider = section === "overview" || section === "slider";
  const showSidebar = section === "overview" || section === "sidebar";
  const composerSnapshot: AcpmuxSnapshot = {
    ...baseComposerSnapshot,
    summary: {
      ...baseComposerSnapshot.summary!,
      model,
      modes: { ...baseComposerSnapshot.summary!.modes!, currentModeId: mode },
      configOptions: baseComposerSnapshot.summary!.configOptions!.map((option) => ({
        ...option,
        currentValue: option.id === "effort" ? effort : option.id === "fast-mode" ? fast : option.currentValue,
      })),
    },
  };

  return (
    <main className="cmux-comparison-board" aria-label="CMUX Next comparison board">
      <div className="cmux-comparison-toolbar">
        <div>
          <p className="cmux-comparison-eyebrow">Interactive comparison board</p>
          <h1>Composer and sidebar treatments</h1>
        </div>
        {/* ui-allow: gallery board uses explicit tab semantics for the comparison fixture. */}
        <div className="cmux-comparison-tabs" role="tablist" aria-label="Comparison sections">
          {(["overview", "slider", "sidebar"] as const).map((name) => (
            <button
              key={name}
              type="button"
              // ui-allow: gallery board uses explicit tab semantics for the comparison fixture.
              role="tab"
              id={`comparison-tab-${name}`}
              aria-controls={`comparison-panel-${name}`}
              aria-selected={section === name}
              className={section === name ? "is-active" : ""}
              onClick={() => setSection(name)}
            >
              {name === "overview" ? "Overview" : name === "slider" ? "Reasoning slider" : "Sidebar previews"}
            </button>
          ))}
        </div>
      </div>

      <div
        className="cmux-comparison-body"
        // ui-allow: gallery board uses explicit tab semantics for the comparison fixture.
        role="tabpanel"
        id={`comparison-panel-${section}`}
        aria-labelledby={`comparison-tab-${section}`}
      >
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
            <span ref={setPreviewAnchor} className="cmux-comparison-preview-anchor" aria-hidden="true" />
            {previewAnchor && (
              <SessionPreviewCard anchor={previewAnchor} open id="comparison-preview-card" previewVariant={preview}>
                <div className="acpmux-session-preview-title">Review the sidebar polish</div>
                <div className="acpmux-session-preview-copy">
                  Card, quiet and outline treatments are ready to compare.
                </div>
                <div className="acpmux-session-preview-meta">
                  <span className="acpmux-session-preview-status acpmux-session-mark-unread">● New activity</span>
                  <span className="acpmux-session-preview-place">⌘ feat/sidebar-preview</span>
                </div>
              </SessionPreviewCard>
            )}
            {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- compact treatment controls are not a form fieldset. */}
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
                  <p>
                    I’m comparing the accent and minimal treatments here. Hover a session to inspect its latest reply.
                  </p>
                  <span className="cmux-comparison-meta">Ready for review · This Mac</span>
                </div>
              </div>
            </div>
            <div className="cmux-comparison-composer" aria-label="Composer preview">
              <div className="cmux-comparison-composer-copy">Ask anything</div>
              <div className="cmux-comparison-composer-row">
                <span className="cmux-comparison-compose-icon" aria-hidden="true">
                  ＋
                </span>
                <span className="cmux-comparison-compose-hint">Attach files or mention a project</span>
                <ComposerPickers
                  snapshot={composerSnapshot}
                  permissionAccess={{ grants }}
                  onModel={setModel}
                  onMode={setMode}
                  onEffort={(id, value) => (id === "fast-mode" ? setFast(value) : setEffort(value))}
                  showPlan
                />
                <button type="button" className="cmux-comparison-send" aria-label="Send message">
                  ↑
                </button>
              </div>
            </div>
            <div
              className="cmux-comparison-slider-specimen"
              aria-label={`Visible ${sliderStyle} reasoning slider specimen`}
            >
              <div className="cmux-comparison-specimen-heading">
                <span>Reasoning slider</span>
                <strong>{sliderStyle === "accent" ? "Accent" : "Minimal"}</strong>
              </div>
              <EffortTrack
                efforts={efforts}
                current={effort}
                fallback="high"
                onPick={setEffort}
                sliderStyle={sliderStyle}
              />
            </div>
            {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- compact treatment controls are not a form fieldset. */}
            <div className="cmux-comparison-slider-toggle" role="group" aria-label="Reasoning slider treatment">
              <span>Reasoning treatment</span>
              {(["accent", "minimal"] as const).map((name) => (
                <span key={name} className={sliderStyle === name ? "is-active" : ""}>
                  {name}
                </span>
              ))}
            </div>
          </div>
        )}
      </div>
    </main>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.comparison-board",
  title: "CMUX composer and sidebar comparison",
  area: "Agent pane",
  experimental: true,
  height: 720,
  widths: { narrow: 520, normal: 860, wide: 1160 },
  anchors: [{ selector: ".cmux-comparison-board" }],
  covers: [
    "agent-session/acpmux/EffortPicker.tsx#EffortPicker",
    "agent-session/acpmux/SessionSidebar.tsx#SessionSidebar",
    "agent-session/acpmux/SessionSidebar.tsx#SessionPreviewCard",
  ],
  checks: {
    anchorMovePx: { value: 0, reason: "Switching comparison sections keeps the gallery entry anchored." },
    layoutShiftMax: { value: 0, reason: "Variant controls replace content inside the gallery entry." },
    longFrameFailMs: { value: 33, reason: "Local section and treatment toggles should remain responsive." },
  },
  load: async () => ComparisonBoard,
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerControls.css"),
      import("./modelPicker.css"),
      import("./ComposerPickers.gallery.css"),
      import("./ComparisonBoard.gallery.css"),
    ]),
  variants: {
    "overview-accent-card": {
      note: "Light or dark theme: real composer controls, accent slider treatment, and card preview.",
      props: { sliderStyle: "accent", previewVariant: "card" },
    },
    "overview-minimal-quiet": {
      note: "Light or dark theme: real composer controls, quieter slider, and quiet preview.",
      props: { sliderStyle: "minimal", previewVariant: "quiet" },
    },
    "overview-minimal-outline": {
      note: "Light or dark theme: real composer controls, minimal slider, and outline preview.",
      props: { sliderStyle: "minimal", previewVariant: "outline" },
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
