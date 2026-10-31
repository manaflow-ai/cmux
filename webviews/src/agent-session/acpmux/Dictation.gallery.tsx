// l10n-allow-file: gallery fixtures, not shipped UI.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { setComposerSettings } from "./composerSettings";
import { DictationMic } from "./DictationMic";
import { deliverDictation, type Dictation } from "./dictation";
import type { DictationUpdate } from "./dictationText";
import { DictationNotice } from "./DictationNotice";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";

type Props = {
  initialState: Dictation["state"];
  initialNotice: DictationUpdate | null;
};

const update = (state: DictationUpdate["state"], extra: Partial<DictationUpdate> = {}): DictationUpdate => ({
  state,
  text: state === "listening" ? "gallery words" : "",
  level: state === "listening" ? 0.72 : 0,
  cancelled: false,
  ...extra,
});

/// A second of speech for the waveform: one level per update, as the host sends about 12 a second.
const SPEECH = [0.12, 0.35, 0.62, 0.48, 0.81, 0.66, 0.3, 0.74, 0.52, 0.9, 0.58];

function GalleryDictation({ initialState, initialNotice }: Props) {
  const [state, setState] = useState<Dictation["state"]>(initialState);
  const [notice, setNotice] = useState<DictationUpdate | null>(initialNotice);
  const [settingsOpened, setSettingsOpened] = useState(false);

  useEffect(() => {
    if (state === "listening") for (const level of SPEECH) deliverDictation(update(state, { level }));
    else deliverDictation(update(state));
  }, [state]);

  const dictation: Dictation = {
    state,
    notice,
    toggle() {
      setState((current) => (current === "idle" ? "listening" : "idle"));
    },
    finish() {
      setState("idle");
    },
    cancel() {
      setState("idle");
    },
    openSettings() {
      setSettingsOpened(true);
    },
    dismiss() {
      setNotice(null);
    },
  };

  return (
    <ShortcutsContext.Provider value={{ [SHORTCUT_ACTIONS.toggleDictation]: "⇧⌘D" }}>
      <div className="acpmux-shell acpmux-dictation-gallery" data-dictation-fixture>
        <div className="acpmux-dictation-notice-host">
          <DictationNotice dictation={dictation} />
        </div>
        <div className="acpmux-composer">
          <div className="ui-glass acpmux-composer-box">
            <div className="acpmux-composer-bar">
              <div className="acpmux-composer-actions">
                <DictationMic dictation={dictation} />
              </div>
            </div>
          </div>
        </div>
        {settingsOpened ? (
          <output className="acpmux-dictation-settings-receipt" data-settings-receipt>
            System Settings requested
          </output>
        ) : null}
      </div>
    </ShortcutsContext.Provider>
  );
}

const start: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Dictate" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Stop dictation" }).getAttribute("aria-pressed") === "true");
};

const finish: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Finish dictation" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-dictation-wave") === null);
};

const stop: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Stop dictation" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Dictate" }).getAttribute("aria-pressed") === "false");
};

/// Right-click Hide Dictation Button takes the mic out of the composer (every composer reads the
/// same setting); the play puts it back as the button row's Show or Settings would.
const hide: Play = async (ctx) => {
  await ctx.contextMenu({ role: "button", name: "Dictate" });
  await ctx.click({ role: "menuitem", name: "Hide Dictation Button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mic") === null);
  setComposerSettings({ showDictation: true });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mic") !== null);
};

const permission: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open voice permissions" });
  await ctx.waitFor(() => ctx.document.querySelector("[data-settings-receipt]") !== null);
  await ctx.click({ role: "button", name: "Dismiss" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="alert"]') === null);
};

export default componentEntry<Props>({
  id: "agent-pane.dictation",
  title: "Composer dictation",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 260, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-dictation-fixture]" }],
  covers: [
    "agent-session/acpmux/DictationButton.tsx#DictationButton",
    "agent-session/acpmux/DictationMic.tsx#DictationMic",
    "agent-session/acpmux/DictationListening.tsx#DictationWave",
    "agent-session/acpmux/DictationListening.tsx#DictationFinishButton",
    "agent-session/acpmux/DictationNotice.tsx#DictationNotice",
  ],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Dictation changes the composer controls in place and must not move the transcript or composer anchor.",
    },
    layoutShiftMax: {
      value: 0,
      reason:
        "The waveform, finish key and permission notice stay inside the composer host instead of reflowing the pane.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Starting and stopping dictation is a local control interaction and should remain within one frame.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Dictation controls and permission dismissal should settle within a quarter second.",
    },
  },
  load: async () => GalleryDictation,
  variants: {
    idle: { props: { initialState: "idle", initialNotice: null } },
    listening: {
      props: { initialState: "listening", initialNotice: null },
      note: "Listening: a waveform of thin bars that fades to dots at both ends, the finish key (⏎), and the lit mic.",
    },
    starting: {
      props: { initialState: "starting", initialNotice: null },
      note: "Starting: the wave rests as dots until the first level arrives; the mic is already lit.",
    },
    finalizing: {
      props: { initialState: "finalizing", initialNotice: null },
      note: "Finalizing: the last words are landing; the wave dims and the finish key waits.",
    },
    start: {
      props: { initialState: "idle", initialNotice: null },
      play: start,
      note: "The mic keeps the composer focused while the waveform and finish key come in beside it.",
    },
    finish: {
      props: { initialState: "listening", initialNotice: null },
      play: finish,
      note: "The finish key ends the session and keeps its words.",
    },
    stop: {
      props: { initialState: "listening", initialNotice: null },
      play: stop,
    },
    hide: {
      props: { initialState: "idle", initialNotice: null },
      play: hide,
      note: "Right-click on the mic hides it in every composer; Settings shows it again.",
    },
    denied: {
      props: {
        initialState: "idle",
        initialNotice: {
          ...update("denied"),
          permission: "microphone",
          message: "Microphone access is blocked for cmux.",
          settingsLabel: "Open voice permissions",
        },
      },
      play: permission,
      note: "A denied microphone keeps the explanation above the composer with direct recovery and dismissal.",
    },
    failed: {
      props: {
        initialState: "idle",
        initialNotice: { ...update("failed"), message: "Dictation could not start." },
      },
    },
  },
});
