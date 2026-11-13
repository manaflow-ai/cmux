// l10n-allow-file: gallery labels are fixture content, not shipped UI.
// FOCUS-RING (focusModality.ts): one owner decides every ring. Each variant ends in one state of the
// rule, driven by trusted keys and pointer: only a Tab that moves focus draws a ring; a click,
// Escape, a pointer move or a shortcut's code focus leaves none, on the shared buttons and on the
// chat composer's rim alike.
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Button } from "./Button";
import { focusModality } from "./focusModality";

function FocusRingGallery() {
  return (
    <div className="acpmux-shell" data-gallery-capture="" style={{ flexDirection: "column", gap: 16, padding: 16 }}>
      <div style={{ display: "flex", gap: 8 }}>
        <Button id="focus-ring-a">Opus 5.5</Button>
        <Button id="focus-ring-b">Plan</Button>
        <Button id="focus-ring-c">Attach</Button>
      </div>
      <div className="acpmux-composer" style={{ inlineSize: 360 }}>
        <div className="ui-glass ui-glass-floats ui-glass-material acpmux-composer-box" style={{ height: 88 }}>
          <div className="acpmux-md" contentEditable suppressContentEditableWarning id="focus-ring-field" />
        </div>
      </div>
    </div>
  );
}

const button = { selector: "#focus-ring-b" };
const field = { selector: "#focus-ring-field" };
const modalityIs = (mode: "keyboard" | "pointer") => () => focusModality() === mode;

/** Tab, Tab: the second button holds focus the keys moved, with its ring. */
const tabbed: Play = async (ctx) => {
  await ctx.click({ selector: "[data-gallery-capture]" });
  await ctx.press("Tab");
  await ctx.press("Tab");
  await ctx.waitFor(modalityIs("keyboard"));
};

export default componentEntry({
  id: "ui.focus-ring",
  title: "Focus ring",
  area: "UI primitives",
  height: 220,
  covers: ["ui/Button.tsx#Button"],
  load: async () => FocusRingGallery,
  styles: () =>
    Promise.all([
      import("./ui.css"),
      import("../agent-session/shared/styles.css"),
      import("../agent-session/acpmux/styles.css"),
      import("../agent-session/acpmux/composerStates.css"),
      import("../agent-session/acpmux/composerLocation.css"),
    ]),
  variants: {
    rest: { props: {}, note: "Nothing focused: no ring anywhere." },
    "tab-earns-ring": { props: {}, play: tabbed, note: "Tab moved focus: the button shows its ring." },
    "click-draws-none": {
      props: {},
      play: async (ctx) => {
        await ctx.click(button);
        await ctx.waitFor(modalityIs("pointer"));
      },
      note: "A click focuses the button with no ring.",
    },
    "escape-cancels": {
      props: {},
      play: async (ctx) => {
        await tabbed(ctx);
        await ctx.press("Escape");
        await ctx.waitFor(modalityIs("pointer"));
      },
      note: "Escape takes the ring away; focus stays on the button.",
    },
    "pointer-move-cancels": {
      props: {},
      play: async (ctx) => {
        await tabbed(ctx);
        await ctx.pointer.move({ selector: "#focus-ring-a" });
        await ctx.pointer.move(field);
        await ctx.waitFor(modalityIs("pointer"));
      },
      note: "Moving the pointer away takes the ring away.",
    },
    "shortcut-focus-draws-none": {
      props: {},
      play: async (ctx) => {
        await tabbed(ctx);
        await ctx.press("Meta+k");
        (ctx.find(field) as HTMLElement).focus(); // what a shortcut does from code (the palette, a pane key)
        await ctx.waitFor(modalityIs("pointer"));
      },
      note: "Focus a shortcut or code moves earns no ring, even right after a Tab.",
    },
    "composer-click-rests": {
      props: {},
      play: async (ctx) => {
        await ctx.click(field);
        await ctx.waitFor(modalityIs("pointer"));
      },
      note: "A click in the prompt: the caret shows, the rim stays at rest.",
    },
    "composer-tab-lights": {
      props: {},
      play: async (ctx) => {
        await ctx.click({ selector: "#focus-ring-c" });
        await ctx.press("Tab");
        await ctx.waitFor(modalityIs("keyboard"));
      },
      note: "Tab into the prompt: the rim brightens its one step.",
    },
  },
});
