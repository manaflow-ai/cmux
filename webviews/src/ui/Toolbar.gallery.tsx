// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Toolbar, ToolbarButton, ToolbarGroup, ToolbarSeparator, ToolbarToggleGroup } from "./Toolbar";

type Props = {
  current?: boolean;
  disabled?: boolean;
};

function ToolbarGallery({ current = true, disabled = true }: Props) {
  const [view, setView] = useState("split");
  const [event, setEvent] = useState("Ready");
  return (
    <div className="toolbar-gallery-stage">
      <div className="toolbar-gallery-copy">
        <strong>Transcript controls</strong>
        <span>One Tab stop, arrow navigation, and a compact view switcher.</span>
      </div>
      <Toolbar label="Transcript controls" className="toolbar-gallery">
        <ToolbarGroup label="History">
          <ToolbarButton label="Back" tooltip={false} onPress={() => setEvent("Back pressed")}>
            ←
          </ToolbarButton>
          <ToolbarButton label="Forward" tooltip={false} onPress={() => setEvent("Forward pressed")}>
            →
          </ToolbarButton>
          <ToolbarButton
            label="Refresh"
            tooltip={false}
            disabled={disabled}
            onPress={() => setEvent("Refresh pressed")}
          >
            ↻
          </ToolbarButton>
        </ToolbarGroup>
        <ToolbarSeparator />
        <ToolbarGroup label="View">
          <ToolbarToggleGroup
            label="View mode"
            value={view}
            options={[
              { value: "split", label: "Split" },
              { value: "unified", label: "Unified" },
            ]}
            onValueChange={(next) => {
              setView(next);
              setEvent(`View: ${next}`);
            }}
          />
          <ToolbarButton
            label="Current section"
            tooltip={false}
            current={current}
            onPress={() => setEvent("Current section")}
          >
            ●
          </ToolbarButton>
        </ToolbarGroup>
      </Toolbar>
      <output className="toolbar-gallery-receipt" data-testid="toolbar-gallery-receipt" aria-live="polite">
        {event}
      </output>
    </div>
  );
}

const keyboardNavigation: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Back" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ role: "button", name: "Forward" }));
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ role: "button", name: "Refresh" }));
};

const toggleView: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Unified" });
  await ctx.waitFor(() => ctx.find({ testId: "toolbar-gallery-receipt" }).textContent === "View: unified");
};

const activate: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Back" });
  await ctx.waitFor(() => ctx.find({ testId: "toolbar-gallery-receipt" }).textContent === "Back pressed");
};

const currentSemantics: Play = async (ctx) => {
  await ctx.waitFor(
    () => ctx.find({ role: "button", name: "Current section" }).getAttribute("aria-current") === "true",
  );
};

export default componentEntry<Props>({
  id: "ui.toolbar",
  title: "Toolbar",
  area: "UI primitives",
  height: 300,
  widths: { narrow: 360, normal: 560, wide: 820 },
  anchors: [{ selector: ".toolbar-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Toolbar focus and view changes must not move the receipt anchor." },
    longFrameFailMs: { value: 33, reason: "Toolbar keyboard feedback should stay within two display frames." },
    settleMaxMs: { value: 250, reason: "Toolbar navigation and toggles are local interactions." },
  },
  covers: [
    "ui/Toolbar.tsx#Toolbar",
    "ui/Toolbar.tsx#ToolbarButton",
    "ui/Toolbar.tsx#ToolbarGroup",
    "ui/Toolbar.tsx#ToolbarSeparator",
    "ui/Toolbar.tsx#ToolbarToggleGroup",
  ],
  load: async () => ToolbarGallery,
  styles: () => Promise.all([import("./ui.css"), import("./Toolbar.gallery.css")]),
  variants: {
    initial: { props: {} },
    keyboard: { props: {}, play: keyboardNavigation },
    "toggle-view": { props: {}, play: toggleView },
    activate: { props: {}, play: activate },
    "current-section": { props: { current: true }, play: currentSemantics },
    "not-current": { props: { current: false } },
    "refresh-enabled": { props: { disabled: false } },
  },
});
