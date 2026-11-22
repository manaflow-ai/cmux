// The stage's tunable editors (experiments/tunable.ts): one curve editor per tunable of the entry.
// A drag moves the curve here at once and changes the URL (and so the stages) when the handle is
// let go; the text field takes any `cubic-bezier()` text. A developer tool: its labels are English.
import { useState } from "react";
import { readTunes, tunableValue, writeTunes, type Tunable } from "../../experiments/tunable";
import {
  BEZIER_Y_RANGE,
  cssBezier,
  formatBezier,
  parseBezier,
  sameBezier,
  type CubicBezier,
} from "../../ui/cubicBezier";

const CSS_PRESETS: Record<string, CubicBezier> = {
  linear: [0, 0, 1, 1],
  ease: [0.25, 0.1, 0.25, 1],
  "ease-in": [0.42, 0, 1, 1],
  "ease-out": [0, 0, 0.58, 1],
  "ease-in-out": [0.42, 0, 0.58, 1],
};

export function Tunables({
  tunables,
  tune,
  onChange,
}: {
  tunables: readonly Tunable[];
  tune: string;
  onChange: (tune: string) => void;
}) {
  const values = readTunes(tune);
  const set = (tunable: Tunable, value: CubicBezier) => {
    const next = { ...values };
    // The shipped value is left out of the URL, as every default is.
    if (sameBezier(value, tunable.defaultValue)) delete next[tunable.id];
    else next[tunable.id] = formatBezier(value);
    onChange(writeTunes(next));
  };
  return (
    <div className="gallery-tunables">
      {tunables.map((tunable) => (
        <BezierEditor
          key={tunable.id}
          tunable={tunable}
          value={tunableValue(tunable, { overrides: values, stored: {} })}
          onChange={(value) => set(tunable, value)}
        />
      ))}
    </div>
  );
}

/** The plot: x 0...1 across, y from the bottom of BEZIER_Y_RANGE's shown part to its top. */
const SIZE = 132;
const PAD = 10;
const Y_LOW = -0.25;
const Y_HIGH = 1.25;
const px = (x: number) => PAD + x * SIZE;
const py = (y: number) => PAD + ((Y_HIGH - y) / (Y_HIGH - Y_LOW)) * SIZE;
const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), high);
const round = (value: number) => Math.round(value * 100) / 100;

function BezierEditor({
  tunable,
  value,
  onChange,
}: {
  tunable: Tunable;
  value: CubicBezier;
  onChange: (value: CubicBezier) => void;
}) {
  // The curve while a handle is held; the URL changes once, when it is let go.
  const [draft, setDraft] = useState<{ handle: 0 | 1; curve: CubicBezier } | null>(null);
  const curve = draft?.curve ?? value;
  const [x1, y1, x2, y2] = curve;
  const presets: Record<string, CubicBezier> = { shipped: tunable.defaultValue, ...tunable.presets, ...CSS_PRESETS };
  const preset = Object.entries(presets).find(([, candidate]) => sameBezier(candidate, curve))?.[0] ?? "custom";

  const pointAt = (event: React.PointerEvent<SVGSVGElement>): [number, number] => {
    const rect = event.currentTarget.getBoundingClientRect();
    const scale = rect.width / (SIZE + 2 * PAD);
    const x = ((event.clientX - rect.left) / scale - PAD) / SIZE;
    const y = Y_HIGH - (((event.clientY - rect.top) / scale - PAD) / SIZE) * (Y_HIGH - Y_LOW);
    return [round(clamp(x, 0, 1)), round(clamp(y, BEZIER_Y_RANGE[0], BEZIER_Y_RANGE[1]))];
  };
  const move = (event: React.PointerEvent<SVGSVGElement>) => {
    if (!draft) return;
    const [x, y] = pointAt(event);
    setDraft({ handle: draft.handle, curve: draft.handle === 0 ? [x, y, x2, y2] : [x1, y1, x, y] });
  };
  const release = () => {
    if (!draft) return;
    setDraft(null);
    if (!sameBezier(draft.curve, value)) onChange(draft.curve);
  };
  const grab = (handle: 0 | 1) => (event: React.PointerEvent<SVGCircleElement>) => {
    event.preventDefault();
    event.currentTarget.ownerSVGElement?.setPointerCapture(event.pointerId);
    setDraft({ handle, curve });
  };
  const commitText = (text: string) => {
    const parsed = parseBezier(text);
    if (parsed && !sameBezier(parsed, value)) onChange(parsed);
  };

  return (
    <fieldset className="gallery-tunable">
      <legend title={tunable.description}>{tunable.title}</legend>
      <svg
        className="gallery-tunable-plot"
        viewBox={`0 0 ${SIZE + 2 * PAD} ${SIZE + 2 * PAD}`}
        width={SIZE + 2 * PAD}
        height={SIZE + 2 * PAD}
        onPointerMove={move}
        onPointerUp={release}
        onPointerCancel={release}
      >
        <rect x={px(0)} y={py(1)} width={SIZE} height={py(0) - py(1)} className="gallery-tunable-box" />
        <line x1={px(0)} y1={py(0)} x2={px(1)} y2={py(1)} className="gallery-tunable-diagonal" />
        <line x1={px(0)} y1={py(0)} x2={px(x1)} y2={py(y1)} className="gallery-tunable-arm" />
        <line x1={px(1)} y1={py(1)} x2={px(x2)} y2={py(y2)} className="gallery-tunable-arm" />
        <path
          d={`M ${px(0)} ${py(0)} C ${px(x1)} ${py(y1)}, ${px(x2)} ${py(y2)}, ${px(1)} ${py(1)}`}
          className="gallery-tunable-curve"
        />
        {([0, 1] as const).map((handle) => (
          <circle
            key={handle}
            cx={px(handle === 0 ? x1 : x2)}
            cy={py(handle === 0 ? y1 : y2)}
            r={6}
            className="gallery-tunable-handle"
            data-held={draft?.handle === handle ? "" : undefined}
            onPointerDown={grab(handle)}
          >
            <title>{handle === 0 ? "First control point" : "Second control point"}</title>
          </circle>
        ))}
      </svg>
      <div className="gallery-tunable-side">
        <label>
          Preset
          <select
            value={preset}
            onChange={(event) => {
              const next = presets[event.target.value];
              if (next) onChange(next);
            }}
          >
            {Object.keys(presets).map((name) => (
              <option key={name} value={name}>
                {name}
              </option>
            ))}
            {preset === "custom" && <option value="custom">custom</option>}
          </select>
        </label>
        {/* Return submits the form; leaving the field commits too. */}
        <form
          onSubmit={(event) => {
            event.preventDefault();
            commitText(new FormData(event.currentTarget).get("value")?.toString() ?? "");
          }}
        >
          <label>
            Value
            <input
              key={formatBezier(curve)}
              name="value"
              aria-label={`${tunable.title} value`}
              defaultValue={formatBezier(curve)}
              spellCheck={false}
              onBlur={(event) => commitText(event.target.value)}
            />
          </label>
        </form>
        <code className="gallery-tunable-css">{cssBezier(curve)}</code>
        {/* The track replays the curve: 0.9 s of motion, then a rest at the end. */}
        <div className="gallery-tunable-track" aria-hidden="true">
          <span key={formatBezier(curve)} style={{ animationTimingFunction: cssBezier(curve) }} />
        </div>
        {/* Always laid out, so a change of value never moves the controls. */}
        <button
          type="button"
          disabled={sameBezier(value, tunable.defaultValue)}
          onClick={() => onChange(tunable.defaultValue)}
        >
          Reset
        </button>
      </div>
    </fieldset>
  );
}
