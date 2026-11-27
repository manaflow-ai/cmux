// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useId, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { ChoiceGroup } from "./ChoiceGroup";

type Props = {
  initialValue?: string;
  busy?: boolean;
  disabled?: boolean;
};

const CHOICES = [
  { value: "balanced", label: "Balanced", detail: "Good for everyday work" },
  { value: "fast", label: "Fast", detail: "Prioritize quick feedback" },
  { value: "thorough", label: "Thorough", detail: "Spend more time checking" },
];

function ChoiceGroupGallery({ initialValue = "balanced", busy = false, disabled = false }: Props) {
  const name = useId();
  const [value, setValue] = useState(initialValue);
  const [event, setEvent] = useState(busy ? "Busy" : "Ready");
  return (
    <div className="choice-group-gallery-stage">
      <div className="choice-group-gallery-copy">
        <strong>Review depth</strong>
        <span>Choose how much validation the next run should perform.</span>
      </div>
      <ChoiceGroup
        label="Review depth"
        className="choice-group-gallery"
        busy={busy}
        onSubmit={() => setEvent(`Submitted ${CHOICES.find((choice) => choice.value === value)?.label ?? value}`)}
        onCancel={() => setEvent("Cancelled")}
      >
        {CHOICES.map((choice) => (
          <label
            key={choice.value}
            className="choice-group-gallery-option"
            htmlFor={`${name}-${choice.value}`}
            aria-label={choice.label}
          >
            <input
              id={`${name}-${choice.value}`}
              type="radio"
              aria-label={choice.label}
              name={name}
              value={choice.value}
              checked={choice.value === value}
              disabled={disabled}
              onChange={() => {
                setValue(choice.value);
                setEvent(`Selected ${choice.label}`);
              }}
            />
            <span className="choice-group-gallery-label">
              <strong>{choice.label}</strong>
              <small>{choice.detail}</small>
            </span>
          </label>
        ))}
      </ChoiceGroup>
      <output className="choice-group-gallery-receipt" data-testid="choice-group-gallery-receipt" aria-live="polite">
        {event}
      </output>
    </div>
  );
}

const submit: Play = async (ctx) => {
  await ctx.focus({ role: "radio", name: "Fast" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ testId: "choice-group-gallery-receipt" }).textContent === "Submitted Fast");
};

const cancel: Play = async (ctx) => {
  await ctx.focus({ role: "radio", name: "Thorough" });
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.find({ testId: "choice-group-gallery-receipt" }).textContent === "Cancelled");
};

export default componentEntry<Props>({
  id: "ui.choice-group",
  title: "Choice group",
  area: "UI primitives",
  height: 360,
  widths: { narrow: 340, normal: 540, wide: 820 },
  anchors: [{ selector: ".choice-group-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Changing a radio choice must not move the stable receipt anchor." },
    longFrameFailMs: {
      value: 33,
      reason: "Radio selection and submit feedback should stay within two display frames.",
    },
    settleMaxMs: { value: 250, reason: "Choice submission and cancellation are local interactions." },
  },
  covers: ["ui/ChoiceGroup.tsx#ChoiceGroup"],
  load: async () => ChoiceGroupGallery,
  styles: () => Promise.all([import("./ui.css"), import("./ChoiceGroup.gallery.css")]),
  variants: {
    initial: { props: {} },
    fast: { props: { initialValue: "fast" } },
    thorough: { props: { initialValue: "thorough" } },
    submit: { props: { initialValue: "fast" }, play: submit },
    cancel: { props: { initialValue: "thorough" }, play: cancel },
    busy: { props: { initialValue: "fast", busy: true } },
    disabled: { props: { initialValue: "balanced", disabled: true } },
  },
});
