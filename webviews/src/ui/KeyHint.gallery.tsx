// l10n-allow-file: gallery labels are fixture content, not shipped UI.
// KEY HINT (ui/KeyHint.tsx): the one way the web UI draws a shortcut. Leo 2026-11-22, on the model
// chip's "Opus 5.5 · 65% of context used ^⌘M" tooltip: "the fuck are we styling our key input hints
// as? fucking go pick the best and centralize our shit." Each variant draws the same specimens (a
// tooltip, a menu, dialog buttons, a palette row with a chord, a card's answer buttons) in one look:
// `plain` is the pick (macOS menus, Claude's tooltips: plain glyphs in the secondary ink);
// `plate` is what shipped before (one filled plate per shortcut, emphasized); `chip` is a filled chip
// per key; `outline` a hairline chip per key (Claude's composer footer).
import { componentEntry } from "../gallery/format";
import { DialogButton } from "./DialogButton";
import { KeyHint } from "./KeyHint";

type Look = "plain" | "plate" | "chip" | "outline";

const MENU: Array<[string, string]> = [
  ["New Chat", "⌘N"],
  ["Switch Model", "⌃⌘M"],
  ["Send Now", "⌘↩"],
  ["Close Tab", "⌘W"],
];

function KeyHintGallery({ look = "plain" }: { look?: Look }) {
  return (
    <div className="khg" data-key-hint-look={look} data-gallery-capture="">
      <section>
        <h3>Tooltip</h3>
        <div className="ui-tooltip ui-glass khg-tooltip">
          <KeyHint keys="⌃⌘M" className="ui-tooltip-hint" />
          <span className="ui-tooltip-text">Opus 5.5 · 65% of context used</span>
        </div>
        <div className="ui-tooltip ui-glass khg-tooltip">
          <KeyHint keys="⌘J" className="ui-tooltip-hint" />
          <span className="ui-tooltip-text">New Agent Chat</span>
        </div>
      </section>
      <section>
        <h3>Menu</h3>
        <div className="khg-menu">
          {MENU.map(([label, keys]) => (
            <div key={label} className="khg-row">
              <span>{label}</span>
              <span className="ui-menu-shortcut">
                <KeyHint keys={keys} />
              </span>
            </div>
          ))}
        </div>
      </section>
      <section>
        <h3>Dialog buttons</h3>
        <div className="khg-buttons">
          <DialogButton className="ui-btn" dialogKey="escape">
            Cancel
          </DialogButton>
          <DialogButton className="ui-btn ui-btn-primary" dialogKey="return">
            Quit
          </DialogButton>
          <DialogButton className="ui-btn" dialogKey={{ command: "d" }}>
            Don’t Save
          </DialogButton>
        </div>
      </section>
      <section>
        <h3>Palette</h3>
        <div className="khg-menu">
          <div className="khg-row is-selected">
            <span>New Agent Chat</span>
            <KeyHint keys={["⌘", "J", "S"]} />
          </div>
          <div className="khg-row">
            <span>Open Settings</span>
            <KeyHint keys="⌘," />
          </div>
          <div className="khg-foot">
            <span>
              Run Command <KeyHint keys="↩" />
            </span>
            <span>
              Actions <KeyHint keys="⇥" />
            </span>
          </div>
        </div>
      </section>
      <section>
        <h3>Card answers</h3>
        <div className="khg-buttons">
          <button type="button" className="khg-answer">
            Deny <KeyHint keys="esc" />
          </button>
          <button type="button" className="khg-answer is-primary">
            Allow <KeyHint keys="⌘↩" />
          </button>
          <button type="button" className="khg-answer">
            Always <KeyHint keys="⌥⌘2" />
          </button>
        </div>
      </section>
    </div>
  );
}

export default componentEntry({
  id: "ui.key-hint",
  title: "Key hint",
  area: "UI primitives",
  height: 520,
  widths: { narrow: 420, normal: 720, wide: 960 },
  covers: ["ui/KeyHint.tsx#KeyHint"],
  load: async () => KeyHintGallery,
  styles: () =>
    Promise.all([
      import("./ui.css"),
      import("./controls.css"),
      import("./popupSurface.css"),
      import("./KeyHint.gallery.css"),
    ]),
  variants: {
    plain: {
      props: { look: "plain" },
      note: "Shipped: the keys as plain glyphs in the secondary ink, caption size, regular weight, no plate, as macOS menus write a shortcut.",
    },
    plate: {
      props: { look: "plate" },
      note: "Before: one filled plate per shortcut, its keys emphasized (the old tooltip and card keycap).",
    },
    chip: {
      props: { look: "chip" },
      note: "A filled chip per key, medium weight.",
    },
    outline: {
      props: { look: "outline" },
      note: "A hairline chip per key, no fill (Claude's composer footer).",
    },
  },
});
