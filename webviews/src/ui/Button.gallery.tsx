// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Button, type ButtonVariant } from "./Button";

type Props = { variant?: ButtonVariant; open?: boolean; disabled?: boolean };

const Plus = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <path d="M8 3v10M3 8h10" strokeLinecap="round" />
  </svg>
);

function ButtonGallery({ variant = "subtle", open = false, disabled = false }: Props) {
  const [count, setCount] = useState(0);
  const press = () => setCount((value) => value + 1);
  return (
    <div className="ui-controls-stage">
      {(["sm", "md", "lg"] as const).map((size) => (
        <div className="ui-controls-row" key={size}>
          <span className="ui-controls-label">{size}</span>
          <Button variant={variant} size={size} onClick={press} disabled={disabled}>
            Run checks
          </Button>
          <Button variant={variant} size={size} icon aria-label={`Add (${size})`} onClick={press} disabled={disabled}>
            <Plus />
          </Button>
          <Button variant={variant} size={size} danger onClick={press} disabled={disabled}>
            Delete
          </Button>
        </div>
      ))}
      <div className="ui-controls-row">
        <span className="ui-controls-label">menu open</span>
        <Button variant={variant} data-popup-open={open ? "" : undefined} aria-expanded={open}>
          Options
        </Button>
      </div>
      <output className="ui-controls-receipt" data-testid="button-receipt">
        Pressed {count}
      </output>
    </div>
  );
}

const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Add (md)" });
  await ctx.press("Enter");
  await ctx.press("Space");
  await ctx.waitFor(() => ctx.find({ testId: "button-receipt" }).textContent === "Pressed 2");
};

export default componentEntry<Props>({
  id: "ui.button",
  title: "Button",
  area: "UI primitives",
  height: 300,
  covers: ["ui/Button.tsx#Button"],
  load: async () => ButtonGallery,
  styles: () => Promise.all([import("./ui.css"), import("./controls.gallery.css")]),
  variants: {
    subtle: { props: { variant: "subtle" }, note: "The default: a quiet fill reads as a control on glass." },
    ghost: { props: { variant: "ghost" }, note: "Toolbar and row-trailing buttons: nothing until hover." },
    solid: { props: { variant: "solid" }, note: "The one primary action of a dialog or sheet." },
    "menu-open": { props: { variant: "ghost", open: true }, note: "Stays lit while the menu it opened is open." },
    disabled: { props: { disabled: true } },
    keyboard: { props: {}, play: keyboard },
  },
});
