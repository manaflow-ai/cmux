// l10n-allow-file: gallery fixtures, not shipped UI.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { setComposerSettings, type DictationSource } from "./composerSettings";
import { DictationMic } from "./DictationMic";
import { deliverDictation, type Dictation } from "./dictation";
import type { DictationUpdate } from "./dictationText";
import { DictationNotice } from "./DictationNotice";
import "./DictationPill.gallery.css";
import { setDictationApps, type InstalledDictationApp } from "./dictationSources";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";

type Props = {
  initialState: Dictation["state"];
  initialNotice: DictationUpdate | null;
  /// `agentPane.dictationSource` (cmux's own unless a variant picks an app).
  source?: DictationSource;
  /// A pill look weighed against the shipped one (DictationPill.gallery.css); none is the shipped pill.
  look?: "contrast" | "accent" | "quiet" | "bare";
};

/// The dictation apps this fixture Mac has, as the host's `dictation.sources` lists them.
const APPS: InstalledDictationApp[] = [
  { id: "chatgpt", bundleId: "com.openai.codex" },
  { id: "wisprFlow", bundleId: "com.electron.wispr-flow" },
];

/// A stand-in app icon (the host draws the real one, `attachment.sourceIcon`): a rounded tile.
function appIcon(bundleId: string): string | undefined {
  const look = bundleId === "com.openai.codex" ? { fill: "#111", letter: "G" } : { fill: "#5b4bdb", letter: "W" };
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 64;
  const ink = canvas.getContext("2d");
  if (!ink) return undefined;
  ink.fillStyle = look.fill;
  ink.beginPath();
  ink.roundRect(4, 4, 56, 56, 14);
  ink.fill();
  ink.fillStyle = "white";
  ink.font = "600 34px -apple-system, system-ui, sans-serif";
  ink.textAlign = "center";
  ink.textBaseline = "middle";
  ink.fillText(look.letter, 32, 34);
  return canvas.toDataURL("image/png");
}

const update = (state: DictationUpdate["state"], extra: Partial<DictationUpdate> = {}): DictationUpdate => ({
  state,
  text: state === "listening" ? "gallery words" : "",
  level: state === "listening" ? 0.72 : 0,
  cancelled: false,
  ...extra,
});

/// A second of speech for the waveform: one level per update, as the host sends about 12 a second.
const SPEECH = [0.12, 0.35, 0.62, 0.48, 0.81, 0.66, 0.3, 0.74, 0.52, 0.9, 0.58];

function GalleryDictation({ initialState, initialNotice, source = "cmux", look }: Props) {
  useState(() => {
    const actions = (window.cmuxAcpmuxActions ??= {});
    actions["attachment.sourceIcon"] = async (params) => {
      const src = typeof params.bundleId === "string" ? appIcon(params.bundleId) : undefined;
      return src ? { src } : {};
    };
    actions["dictation.sources"] = async () => ({ sources: APPS });
    setDictationApps(APPS);
    setComposerSettings({ dictationSource: source });
    return null;
  });
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
      <div
        className={`acpmux-shell acpmux-dictation-gallery${look ? ` acpmux-dictation-gallery--${look}` : ""}`}
        data-dictation-fixture
      >
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
    "agent-session/acpmux/DictationListening.tsx#DictationStrip",
    "agent-session/acpmux/DictationNotice.tsx#DictationNotice",
    "agent-session/acpmux/dictationSources.ts#useDictationApps",
  ],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Dictation changes the composer controls in place and must not move the transcript or composer anchor.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The waveform and permission notice stay inside the composer host instead of reflowing the pane.",
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
      note: 'Shipped. Listening: a compact solid pill holding a waveform of thin bars that fades to dots at both ends, and the lit mic; no send of its own (the composer\'s Send ends the session). The pill follows the theme: dark in a dark theme, its light counterpart in a light one (Leo 2026-11-08: "are you able to have it be, like, the [...] black pill?").',
    },
    "pill-contrast": {
      props: { initialState: "listening", initialNotice: null, look: "contrast" },
      note: "Weighed: the theme's ink as the pill (dark in a light theme, light in a dark one). Loudest of the looks; in a dark theme it is a white capsule, not the dark one asked for.",
    },
    "pill-accent": {
      props: { initialState: "listening", initialNotice: null, look: "accent" },
      note: "Weighed: the themed pill with accent-colored bars. Reads as a second lit control beside the lit mic.",
    },
    "pill-quiet": {
      props: { initialState: "listening", initialNotice: null, look: "quiet" },
      note: "Weighed: the themed pill with dimmed bars. Calm, but the level reads poorly on the pill.",
    },
    "pill-bare": {
      props: { initialState: "listening", initialNotice: null, look: "bare" },
      note: "Before: the waveform alone, with no pill.",
    },
    "source-menu": {
      props: { initialState: "idle", initialNotice: null },
      play: async (ctx) => ctx.contextMenu({ role: "button", name: "Dictate" }),
      note: "The mic's right-click picks what it dictates with: cmux, macOS Dictation, and each dictation app this Mac has (here ChatGPT and Wispr Flow), above Hide Dictation Button.",
    },
    "source-chatgpt": {
      props: { initialState: "idle", initialNotice: null, source: "chatgpt" },
      note: "Dictating with ChatGPT: the mic wears ChatGPT's icon at the glyph's size, and its press sends ChatGPT's shortcut (Leo 2026-11-07: \"maybe you can map the button to that thing\").",
    },
    "source-pick": {
      props: { initialState: "idle", initialNotice: null },
      play: async (ctx) => {
        await ctx.contextMenu({ role: "button", name: "Dictate" });
        await ctx.click({ role: "menuitemcheckbox", name: "Dictate with ChatGPT" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-mic[data-source="chatgpt"] img') !== null);
      },
      note: "Picking ChatGPT in the menu puts its icon on the mic in place, with no layout change.",
    },
    "source-unavailable": {
      props: {
        initialState: "idle",
        initialNotice: {
          ...update("failed"),
          message: "To send ChatGPT's shortcut, allow cmux in System Settings > Privacy & Security > Accessibility.",
        },
        source: "chatgpt",
      },
      note: "A hand-off the host could not make says why above the composer, naming the app.",
    },
    "idle-menu": {
      props: { initialState: "idle", initialNotice: null },
      play: async (ctx) => ctx.contextMenu({ role: "button", name: "Dictate" }),
      note: "The idle mic keeps its quiet hover wash while its Hide menu is open.",
    },
    "listening-menu": {
      props: { initialState: "listening", initialNotice: null },
      play: async (ctx) => ctx.contextMenu({ role: "button", name: "Stop dictation" }),
      note: "The listening mic retains its accent hover tone while its Hide menu is open.",
    },
    starting: {
      props: { initialState: "starting", initialNotice: null },
      note: "Starting: the wave rests as dots until the first level arrives; the mic is already lit.",
    },
    finalizing: {
      props: { initialState: "finalizing", initialNotice: null },
      note: "Finalizing: the last words are landing; the wave dims.",
    },
    start: {
      props: { initialState: "idle", initialNotice: null },
      play: start,
      note: "The mic keeps the composer focused while the pill comes in beside it, on the shared presence motion; the mic and the row stay where they are.",
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
