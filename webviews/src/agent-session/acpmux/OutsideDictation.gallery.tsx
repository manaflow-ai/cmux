// l10n-allow-file: gallery fixtures, not shipped UI.
// Another app's dictation as the composer shows it (outsideDictation.ts), in the three looks it was
// weighed in: the drawn wave in the mic's place (shipped), a macOS-style orange dot on the mic's
// corner, and a soft ring around the mic. Each keeps the mic's footprint, takes no focus and lets
// typing go on (the `typing` play types while it shows).
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { setComposerSettings, type DictationSource } from "./composerSettings";
import { DictationMic } from "./DictationMic";
import type { Dictation } from "./dictation";
import { setDictationApps } from "./dictationSources";
import { setOutsideDictation } from "./outsideDictation";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";

type Look = "wave" | "dot" | "ring";
type Props = { look: Look; source?: DictationSource; name?: string; active?: boolean };

const idle: Dictation = {
  state: "idle",
  notice: null,
  toggle() {},
  finish() {},
  cancel() {},
  openSettings() {},
  dismiss() {},
};

function GalleryOutsideDictation({ look, source = "cmux", name = "ChatGPT", active = true }: Props) {
  const [text, setText] = useState("");
  useState(() => {
    const actions = (window.cmuxAcpmuxActions ??= {});
    actions["dictation.watchMicrophone"] = async (params) => {
      // The host's answer as it comes: the app holding the mic while the composer is focused.
      setTimeout(
        () =>
          setOutsideDictation(
            params.on === true && active ? { active: true, bundleId: "com.openai.codex", name } : { active: false },
          ),
        0,
      );
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
    wave: {
      props: { look: "wave" },
      play: listening,
      note: 'Shipped: three thin bars rise and fall slowly in the mic\'s place while ChatGPT holds the microphone; the tooltip says "ChatGPT is using the microphone". Drawn, not measured: cmux never hears the audio.',
    },
    dot: {
      props: { look: "dot" },
      play: listening,
      note: "Weighed: macOS's orange dot on the mic's corner. Familiar, but reads as cmux recording, which it is not.",
    },
    ring: {
      props: { look: "ring" },
      play: listening,
      note: "Weighed: a still orange ring around the mic. Clear, but louder than a composer you keep typing in should be.",
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
      props: { look: "wave" },
      play: typing,
      note: "Typing goes on while the mark shows; it never takes focus and the mic does not move.",
    },
  },
});
