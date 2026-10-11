// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Disclosure, type DisclosureProps } from "./Disclosure";

type Props = {
  defaultOpen?: boolean;
  controlled?: boolean;
};

function DisclosureGallery({ defaultOpen = false, controlled = false }: Props) {
  const [open, setOpen] = useState(defaultOpen);
  const [event, setEvent] = useState(defaultOpen ? "Opened by default" : "Ready");
  const controlledProps: Partial<DisclosureProps> = controlled ? { open } : { defaultOpen };
  const onOpenChange = (next: boolean) => {
    if (controlled) setOpen(next);
    setEvent(next ? "Opened" : "Closed");
  };
  return (
    <div className="disclosure-gallery-stage">
      <div className="disclosure-gallery-copy">
        <strong>Project details</strong>
        <span>Progressive disclosure keeps secondary information close without adding a new page.</span>
      </div>
      <Disclosure
        {...controlledProps}
        label={
          <>
            <span>Advanced settings</span>
            <span className="disclosure-gallery-chevron" aria-hidden="true" />
          </>
        }
        className="disclosure-gallery"
        onOpenChange={onOpenChange}
      >
        <div className="disclosure-gallery-panel" data-testid="disclosure-gallery-panel">
          <p>Keep generated artifacts and command output attached to this project.</p>
          <button
            type="button"
            className="ui-button disclosure-gallery-action"
            onClick={() => setEvent("Action chosen")}
          >
            Choose artifact folder
          </button>
        </div>
      </Disclosure>
      <output className="disclosure-gallery-receipt" data-testid="disclosure-gallery-receipt" aria-live="polite">
        {event}
      </output>
    </div>
  );
}

const isOpen = (ctx: Parameters<Play>[0]) =>
  ctx.find({ role: "button", name: "Advanced settings" }).getAttribute("aria-expanded") === "true";

const panelVisible = (ctx: Parameters<Play>[0]) => {
  const panel = ctx.find({ testId: "disclosure-gallery-panel" });
  return !panel.hasAttribute("hidden") && panel.getClientRects().length > 0;
};

const clickToggle: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Advanced settings" });
  await ctx.waitFor(() => isOpen(ctx) && panelVisible(ctx));
  await ctx.click({ role: "button", name: "Advanced settings" });
  await ctx.waitFor(() => !isOpen(ctx));
};

const keyboardToggle: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Advanced settings" });
  await ctx.press("Space");
  await ctx.waitFor(() => isOpen(ctx));
  await ctx.press("Enter");
  await ctx.waitFor(() => !isOpen(ctx));
};

const controlledFeedback: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Advanced settings" });
  await ctx.waitFor(() => ctx.find({ testId: "disclosure-gallery-receipt" }).textContent === "Opened");
  await ctx.click({ role: "button", name: "Advanced settings" });
  await ctx.waitFor(() => ctx.find({ testId: "disclosure-gallery-receipt" }).textContent === "Closed");
};

const panelAction: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Advanced settings" });
  await ctx.waitFor(() => panelVisible(ctx));
  await ctx.click({ role: "button", name: "Choose artifact folder" });
  await ctx.waitFor(() => ctx.find({ testId: "disclosure-gallery-receipt" }).textContent === "Action chosen");
};

export default componentEntry<Props>({
  id: "ui.disclosure",
  title: "Disclosure",
  area: "UI primitives",
  height: 320,
  widths: { narrow: 340, normal: 540, wide: 820 },
  anchors: [{ selector: ".disclosure-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening the disclosure must not move the stable receipt anchor." },
    longFrameFailMs: {
      value: 33,
      reason: "Disclosure keyboard and action feedback should stay within two display frames.",
    },
    settleMaxMs: { value: 250, reason: "Disclosure toggles are local interactions." },
  },
  covers: ["ui/Disclosure.tsx#Disclosure"],
  load: async () => DisclosureGallery,
  styles: () => Promise.all([import("./ui.css"), import("./Disclosure.gallery.css")]),
  variants: {
    closed: { props: {} },
    open: { props: { defaultOpen: true } },
    "click-toggle": { props: {}, play: clickToggle },
    keyboard: { props: {}, play: keyboardToggle },
    controlled: { props: { controlled: true }, play: controlledFeedback },
    "panel-action": { props: {}, play: panelAction },
  },
});
