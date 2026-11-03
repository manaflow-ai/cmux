// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Button, buttonClass, type ButtonSize, type ButtonVariant } from "./Button";

const VARIANTS: ButtonVariant[] = ["primary", "secondary", "outline", "ghost", "destructive"];
const SIZES: Exclude<ButtonSize, "icon" | "icon-sm">[] = ["sm", "md", "lg"];

function PlusIcon() {
  return (
    <svg viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M7 2.5v9M2.5 7h9" strokeLinecap="round" />
    </svg>
  );
}

function ButtonGallery({ disabled = false }: { disabled?: boolean }) {
  const [pressed, setPressed] = useState("Ready");
  return (
    <div className="button-gallery-stage">
      {SIZES.map((size) => (
        <div key={size} className="button-gallery-row">
          {VARIANTS.map((variant) => (
            <Button
              key={variant}
              variant={variant}
              size={size}
              disabled={disabled}
              onClick={() => setPressed(`${variant} ${size}`)}
            >
              {variant[0].toUpperCase() + variant.slice(1)}
            </Button>
          ))}
        </div>
      ))}
      <div className="button-gallery-row">
        <Button variant="primary" disabled={disabled}>
          <PlusIcon />
          New chat
        </Button>
        <Button variant="ghost" size="icon" aria-label="Add" disabled={disabled}>
          <PlusIcon />
        </Button>
        <Button variant="outline" size="icon-sm" aria-label="Add" disabled={disabled}>
          <PlusIcon />
        </Button>
        <a className={buttonClass({ variant: "outline" })} href="#docs">
          Link as button
        </a>
      </div>
      <output className="button-gallery-receipt" data-testid="button-gallery-receipt" aria-live="polite">
        {pressed}
      </output>
    </div>
  );
}

const pressPrimary: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Primary" });
  await ctx.waitFor(() => ctx.find({ testId: "button-gallery-receipt" }).textContent === "primary sm");
};

export default componentEntry<{ disabled?: boolean }>({
  id: "ui.button",
  title: "Button",
  area: "UI primitives",
  height: 260,
  widths: { narrow: 420, normal: 620, wide: 820 },
  anchors: [{ selector: ".button-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Pressing a button must not move the receipt." },
    settleMaxMs: { value: 250, reason: "A press is a local interaction." },
  },
  covers: ["ui/Button.tsx"],
  load: async () => ButtonGallery,
  styles: () => Promise.all([import("./ui.css"), import("./button.css"), import("./Button.gallery.css")]),
  variants: {
    all: { props: {} },
    disabled: { props: { disabled: true } },
    press: { props: {}, play: pressPrimary },
  },
});
