// l10n-allow-file: gallery fixtures, not shipped UI.
// Another app's dictation as the composer shows it (outsideDictation.ts). Metered (cmux already has
// microphone permission), the waveform's bars follow the measured input level in the mic's place
// (shipped: `measured-speaking`), weighed against a thinner set and an accent tint. Without
// permission, the drawn wave (`wave`), weighed against an orange dot on the mic's corner and a soft
// ring. Each keeps the mic's footprint, takes no focus and lets typing go on (the `typing` play
// types while it shows).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { setComposerSettings, type DictationSource } from "./composerSettings";
import { DictationMic } from "./DictationMic";
import type { Dictation } from "./dictation";
import { setDictationApps } from "./dictationSources";
import { setOutsideDictation, setOutsideLevel } from "./outsideDictation";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";

type Look = "wave" | "dot" | "ring" | "thin" | "accent";
/// `levels`: the host meters, and these are its last `micLevel` values (oldest first).
type Props = { look: Look; source?: DictationSource; name?: string; active?: boolean; levels?: number[] };

/// A third of a second of speech, then near silence, as the host sends about 12 levels a second.
const SPEAKING = [0.34, 0.71, 0.48, 0.86];
const QUIET = [0.03, 0.05, 0.02, 0.04];

const idle: Dictation = {
  state: "idle",
  notice: null,
  toggle() {},
  finish() {},
  cancel() {},
  openSettings() {},
  dismiss() {},
};

function GalleryOutsideDictation({ look, source = "cmux", name = "ChatGPT", active = true, levels }: Props) {
  const [text, setText] = useState("");
  useState(() => {
    const actions = (window.cmuxAcpmuxActions ??= {});
    actions["dictation.watchMicrophone"] = async (params) => {
      // The host's answer as it comes: the app holding the mic while the composer is focused.
      setTimeout(() => {
        const on = params.on === true && active;
        setOutsideDictation(
          on
            ? { active: true, bundleId: "com.openai.codex", name, metered: levels ? true : undefined }
            : { active: false },
        );
        if (on) for (const level of levels ?? []) setOutsideLevel({ level });
      }, 0);
      return {};
    };
    actions["dictation.sources"] = async () => ({ sources: [] });
    setDictationApps([]);
    setComposerSettings({ dictationSource: source });
    return null;
  });
  return (
    <ShortcutsContext.Provider value={{ [SHORTCUT_ACTIONS.toggleDictation]: "⇧⌘D" }}>
      <div className={`acpmux-shell outside-gallery--${look}`} data-outside-fixture>
        <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
          <div className="ui-glass acpmux-composer-box">
            <textarea
              className="acpmux-composer-prompt"
              aria-label="Prompt"
              value={text}
              onChange={(event) => setText(event.target.value)}
              rows={2}
              style={{ width: "100%", resize: "none", border: 0, background: "transparent", color: "inherit" }}
            />
            <div className="acpmux-composer-bar">
              <div className="acpmux-composer-actions">
                <DictationMic dictation={idle} />
              </div>
            </div>
          </div>
        </form>
      </div>
    </ShortcutsContext.Provider>
  );
}

/// The composer gets the keyboard, as the person's click would: only then does the host watch.
const listening: Play = async (ctx) => {
  await ctx.focus({ role: "textbox", name: "Prompt" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mic[data-outside]") !== null);
};

/// The mark never takes the keyboard: typing goes on in the prompt while it shows.
const typing: Play = async (ctx) => {
  const prompt = ctx.find({ role: "textbox", name: "Prompt" }) as HTMLTextAreaElement;
  prompt.focus();
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mic[data-outside]") !== null);
  const before = ctx.document.querySelector(".acpmux-mic")!.getBoundingClientRect();
  await ctx.type("still typing while ChatGPT listens");
  await ctx.waitFor(() => prompt.value.includes("still typing"));
  const after = ctx.document.querySelector(".acpmux-mic")!.getBoundingClientRect();
  if (ctx.document.activeElement !== prompt) throw new Error("the mark took focus");
  if (before.width !== after.width || before.left !== after.left) throw new Error("the mic moved");
};

export default componentEntry<Props>({
  id: "agent-pane.outside-dictation",
  title: "Composer: another app's dictation",
  area: "Agent pane",
  pane: true,
  height: 160,
  widths: { narrow: 260, normal: 520 },
  anchors: [{ selector: "[data-outside-fixture]" }],
  covers: [
    "agent-session/acpmux/outsideDictation.ts#useOutsideDictation",
    "agent-session/acpmux/DictationButton.tsx#DictationButton",
  ],
  styles: () => Promise.all([import("./styles.css"), import("./OutsideDictation.gallery.css")]),
  checks: {
    anchorMovePx: { value: 0, reason: "The mark draws in the mic's place and never moves the composer." },
    layoutShiftMax: { value: 0, reason: "Nothing reflows when another app takes or releases the microphone." },
  },
  load: async () => GalleryOutsideDictation,
  variants: {
    "measured-speaking": {
      props: { look: "wave", levels: SPEAKING },
      play: listening,
      note: "Shipped, with microphone permission: four bars in the mic's place follow the measured input level while ChatGPT dictates, newest on the right, drawn as cmux's own waveform (2pt bars, muted ink, tapered). The tooltip still says \"ChatGPT is using the microphone\"; cmux keeps no audio.",
    },
    "measured-quiet": {
      props: { look: "wave", levels: QUIET },
      play: listening,
      note: "Shipped look, near silence: the bars rest as dots, so a pause reads as a pause, not as a fault.",
    },
    "measured-thin": {
      props: { look: "thin", levels: SPEAKING },
      play: listening,
      note: "Weighed: the same measured bars at half width. Lighter, but at the mic's size the level is harder to read and it no longer matches cmux's own waveform.",
    },
    "measured-accent": {
      props: { look: "accent", levels: SPEAKING },
      play: listening,
      note: "Weighed: the measured bars in the accent color. Reads as cmux recording, which it is not; the muted ink says another app holds the mic.",
    },
    wave: {
      props: { look: "wave" },
      play: listening,
      note: 'Without microphone permission (cmux never asks for it here): three thin bars rise and fall slowly in the mic\'s place while ChatGPT holds the microphone; the tooltip says "ChatGPT is using the microphone". Drawn, not measured.',
    },
    dot: {
      props: { look: "dot" },
      play: listening,
      note: "Weighed, without permission: an orange dot on the mic's corner. Familiar, but reads as cmux recording, which it is not.",
    },
    ring: {
      props: { look: "ring" },
      play: listening,
      note: "Weighed, without permission: a still orange ring around the mic. Clear, but louder than a composer you keep typing in should be.",
    },
    "wave-app-source": {
      props: { look: "wave", source: "chatgpt" },
      play: listening,
      note: "With ChatGPT as the mic's source, the wave takes the place of ChatGPT's icon while it listens; a press sends ChatGPT's shortcut again.",
    },
    "wave-unknown-app": {
      props: { look: "wave", name: "zoom.us" },
      play: listening,
      note: "Any app holding the mic shows the same mark, named in the tooltip.",
    },
    "no-outside": {
      props: { look: "wave", active: false },
      note: "Nobody else uses the microphone: the plain mic, nothing added.",
    },
    typing: {
      props: { look: "wave", levels: SPEAKING },
      play: typing,
      note: "Typing goes on while the mark shows; it never takes focus and the mic does not move.",
    },
  },
});
