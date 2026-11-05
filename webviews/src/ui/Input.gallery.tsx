// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Input, type InputVariant } from "./Input";

type Props = { variant?: InputVariant; value?: string; disabled?: boolean };

function InputGallery({ variant = "filled", value = "", disabled = false }: Props) {
  const [text, setText] = useState(value);
  return (
    <div className="ui-controls-stage">
      {(["sm", "md", "lg"] as const).map((size) => (
        <Input
          key={size}
          className="ui-controls-field"
          variant={variant}
          size={size}
          placeholder={`Search (${size})`}
          aria-label={`Search (${size})`}
          value={size === "md" ? text : undefined}
          onChange={size === "md" ? (event) => setText(event.currentTarget.value) : undefined}
          disabled={disabled}
        />
      ))}
      <output className="ui-controls-receipt" data-testid="input-receipt">
        {text || "empty"}
      </output>
    </div>
  );
}

const typing: Play = async (ctx) => {
  await ctx.type("sonnet", { role: "textbox", name: "Search (md)" });
  await ctx.waitFor(() => ctx.find({ testId: "input-receipt" }).textContent === "sonnet");
};

export default componentEntry<Props>({
  id: "ui.input",
  title: "Input",
  area: "UI primitives",
  height: 240,
  covers: ["ui/Input.tsx#Input"],
  load: async () => InputGallery,
  styles: () => Promise.all([import("./ui.css"), import("./controls.gallery.css")]),
  variants: {
    filled: { props: { variant: "filled" }, note: "The default: Settings' fields, a quiet fill and no ring." },
    outline: { props: { variant: "outline" } },
    plain: { props: { variant: "plain" }, note: "A field inside its own box (a popup's search row)." },
    "filled-value": { props: { variant: "filled", value: "claude-opus" } },
    disabled: { props: { disabled: true } },
    typing: { props: {}, play: typing },
  },
});
