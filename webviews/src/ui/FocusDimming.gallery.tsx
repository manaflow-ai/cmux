// l10n-allow-file: gallery fixtures, not shipped UI.
// Inactive window and unfocused pane dimming (experiments.focusDimming; ui/focusDimming.css). A
// mock desktop: two overlapping windows, one key and one inactive, and a window split three ways
// with one focused pane. Each mock window carries the attributes the host puts on <html> in the
// app (data-focus-dimming, data-page-inactive, data-pane-unfocused and --cmux-focus-dim), so key
// and inactive, focused and unfocused show side by side under the app's own stylesheet. In the app
// the split panes are native and dim natively by the same slider; the web panes here show what the
// agent pane does when the host marks it unfocused.
import { useEffect, useState, type CSSProperties } from "react";
import wallpaper from "../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../gallery/format";
import { Button } from "./Button";

type Scheme = "dark" | "light";
type Props = {
  /** The slider, in percent (the host's --cmux-focus-dim is this over 100). */
  dim: number;
  scheme: Scheme;
  /** experiments.focusDimming; off draws today's look. */
  dimming: boolean;
};

const DOTS = ["rgb(255, 95, 87)", "rgb(254, 188, 46)", "rgb(40, 200, 64)"];

/** The attributes the host sets on <html>, here on one mock window. */
function scope(dimming: boolean, dim: number, key: boolean, paneUnfocused = false) {
  return {
    "data-focus-dimming": dimming ? "" : undefined,
    "data-page-inactive": key ? undefined : "",
    "data-pane-unfocused": paneUnfocused ? "" : undefined,
    "data-key": key ? "" : undefined,
    style: dimming ? ({ "--cmux-focus-dim": String(dim / 100) } as CSSProperties) : undefined,
  };
}

function TitleBar({ title }: { title: string }) {
  return (
    <div className="fdg-titlebar ui-glass">
      <div className="fdg-dots" aria-hidden>
        {DOTS.map((color) => (
          <span key={color} className="fdg-dot" style={{ "--fdg-dot": color } as CSSProperties} />
        ))}
      </div>
      <span className="fdg-title">{title}</span>
      <span className="fdg-tool" aria-hidden>
        ⌕
      </span>
      <span className="fdg-tool" data-lit="" aria-hidden>
        ◧
      </span>
    </div>
  );
}

function Sidebar() {
  return (
    <div className="fdg-sidebar ui-glass">
      <span className="fdg-muted">Workspaces</span>
      <span className="fdg-row" data-selected="">
        <span className="fdg-row-dot" />
        api-server
      </span>
      <span className="fdg-row">web-client</span>
      <span className="fdg-row">docs</span>
    </div>
  );
}

function Chat({ label, data }: { label?: string; data?: Record<string, string | undefined> }) {
  return (
    <div className="fdg-content" {...data}>
      {label ? <span className="fdg-pane-label">{label}</span> : null}
      <span className="fdg-heading">Retry the flaky upload</span>
      <span className="fdg-text">
        The upload retries three times with backoff. See <span className="fdg-link">retry.ts</span>.
      </span>
      <span className="fdg-muted">Edited 2 files · 14 lines</span>
      <div className="fdg-composer">
        Ask anything
        <span className="fdg-send" aria-hidden>
          ↑
        </span>
      </div>
    </div>
  );
}

function FocusDimmingGallery({ dim: dimProp, scheme, dimming }: Props) {
  const [dim, setDim] = useState(dimProp);
  const [keyFront, setKeyFront] = useState(true);
  const [focused, setFocused] = useState(0);
  useEffect(() => setDim(dimProp), [dimProp]);

  const pane = (index: number) => {
    const unfocused = focused !== index;
    return {
      "data-focus-pane": "",
      "data-pane-unfocused": unfocused && dimming ? "" : undefined,
      "data-page-inactive": unfocused ? "" : undefined,
    };
  };

  return (
    <div className="fdg-desk" data-scheme={scheme} style={{ backgroundImage: `url(${wallpaper})` }}>
      <div className="fdg-scene">
        <div className="fdg-pair">
          <div className="fdg-window" data-slot="back" {...scope(dimming, dim, !keyFront)}>
            <TitleBar title={keyFront ? "Inactive window" : "Key window"} />
            <div className="fdg-body">
              <Sidebar />
              <Chat />
            </div>
          </div>
          <div className="fdg-window" data-slot="front" {...scope(dimming, dim, keyFront)}>
            <TitleBar title={keyFront ? "Key window" : "Inactive window"} />
            <div className="fdg-body">
              <Sidebar />
              <Chat />
            </div>
          </div>
        </div>
        <div className="fdg-split-wrap">
          <div className="fdg-window" {...scope(dimming, dim, true)}>
            <TitleBar title="Split, one pane focused" />
            <div className="fdg-panes">
              {[0, 1, 2].map((index) => (
                <Chat key={index} label={focused === index ? "Focused" : "Unfocused"} data={pane(index)} />
              ))}
            </div>
          </div>
        </div>
      </div>
      <div className="fdg-controls ui-glass">
        <label className="fdg-caption">
          Dim{" "}
          <input
            type="range"
            min={0}
            max={100}
            value={dim}
            disabled={!dimming}
            onChange={(event) => setDim(Number(event.currentTarget.value))}
          />
        </label>
        <span className="fdg-value fdg-caption">{dimming ? `${dim}%` : "Off"}</span>
        <Button size="sm" onClick={() => setKeyFront((front) => !front)}>
          Switch key window
        </Button>
        <Button size="sm" onClick={() => setFocused((index) => (index + 1) % 3)}>
          Focus next pane
        </Button>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.focus-dimming",
  title: "Focus dimming",
  area: "Pages",
  experimental: true,
  height: 600,
  covers: ["ui/focusDimming.css"],
  keywords: ["inactive window", "key window", "unfocused pane", "split", "dim", "desaturate"],
  load: async () => FocusDimmingGallery,
  styles: () =>
    Promise.all([import("./glass/glass.css"), import("./focusDimming.css"), import("./FocusDimming.gallery.css")]),
  options: [
    { id: "dimming", label: "Focus dimming", kind: "toggle", defaultValue: true },
    {
      id: "dim",
      label: "Dim",
      kind: "choice",
      numeric: true,
      choices: [
        { value: "20", label: "20%" },
        { value: "35", label: "35%" },
        { value: "60", label: "60%" },
      ],
      defaultValue: "35",
    },
  ],
  variants: {
    "default-dark": {
      note: "The default dim (0.35): the inactive window's accent, lit glyph and glass lose their colour while its text stays as legible; two of the three split panes fade by half the dim.",
      props: { dim: 35, scheme: "dark", dimming: true },
    },
    "default-light": {
      note: "The default dim in a light theme.",
      props: { dim: 35, scheme: "light", dimming: true },
    },
    "dim-20": { note: "A light touch (0.2).", props: { dim: 20, scheme: "dark", dimming: true } },
    "dim-60": {
      note: "A strong dim (0.6): the inactive window is nearly grey, unfocused panes fade by 0.3.",
      props: { dim: 60, scheme: "dark", dimming: true },
    },
    "dim-60-light": { note: "A strong dim in a light theme.", props: { dim: 60, scheme: "light", dimming: true } },
    "off-dark": {
      note: "experiments.focusDimming off: today's look, only the window buttons go grey (the system's own).",
      props: { dim: 35, scheme: "dark", dimming: false },
    },
    "off-light": {
      note: "Off, in a light theme.",
      props: { dim: 35, scheme: "light", dimming: false },
    },
  },
});
