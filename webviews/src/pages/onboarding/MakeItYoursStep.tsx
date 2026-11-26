// Make cmux Yours (cmux#48416, cmux#49636): a new person's one setup screen (screen "all", what ships),
// or, behind `experiments.introWalk` (off by default), the intro walk's four screens (hq RFD 0057): 1 Pick a look
// (five whole-app look tiles, each with a light and a dark face, and the Tidy switch), 2 How you work,
// 3 Trust and noise (the agents' permission, explained per mode, and banners and sound), 4 Tune (density,
// asked only here, and the background rows below). Each opens on what the settings hold, so Return four
// times is a good setup. The look, trust and noise rows are walk.ts's writes, one publish per click.
// The rows of screens 2 (How you work, Where chats run) and 4 (Density, Background):
//   1. How you work: Agents first (recommended; Cmd-T opens the New Tab page, where a chat starts) or
//      Terminal first (Cmd-T opens a terminal). The words never say "classic".
//   1b. Where chats run: This Mac (the default) or Cloud (`agentPane.newChatsIn`), each with one
//      caption, so a Mac with no agent installed still has a way to start (ask c-8f5f7ff8b3). An
//      older host that sends no `chatsRunIn` gets no row.
//   2. Density: every density Settings has, by Settings' names (the host sends them).
//   3. Background: None, Shuffle Paintings or one of a few built-in works, then the two rows
//      Settings > Appearance draws under its own picker: Opacity (how much of the theme color covers
//      the picture) and Material (None, Frosted, Glass, Clear Glass). With no picture they stay in
//      place, dimmed and inert, so picking one never moves the window's layout.
// Density and Material are segmented tracks whose selection plate slides (ui/motion/SlidingIndicator).
// No theme row: windows follow macOS's light or dark mode, and the terminal theme stays in Settings.
// Each choice is a group of native radios (the browser owns roles, arrows and focus); a pick is sent
// at once and the host writes it, so the app behind the window changes while the person watches.
// Continue keeps the picks; Skip (and Escape) puts back what was set when the window opened.
// Return presses Continue, Escape skips (the page's own key handler).
//
// The `preview` look (the one that ships) also draws a small cmux window built from the three
// answers: the painting behind it, a chat or a terminal in it, its rows as tight as the density.
// The onboarding window covers the app it changes, so this is where a pick is seen. It is drawn from
// the state alone and is hidden from assistive tech: the radios carry every answer.
import { useRef, useState, type CSSProperties, type ReactNode } from "react";
import { cx } from "../../ui/cx";
import { Button } from "../../ui/Button";
import { Switch } from "../../ui/Switch";
import { SlidingIndicator } from "../../ui/motion/SlidingIndicator";
import type { ChatsRunIn, MakeItYoursBackground, MakeItYoursMaterial, MakeItYoursState, WorkStyle } from "./ops";
import { HostIcon, useOnboarding } from "./parts";
import {
  LOOK_BUNDLES,
  NOISES,
  PERMISSIONS,
  bundleWrites,
  noise,
  noiseWrites,
  permission,
  permissionWrites,
  pickedBundle,
  tidyOn,
  tidyWrites,
  walkValues,
  type MakeItYoursScreen,
  type WalkValues,
  type WalkWrite,
} from "./walk";
import { SHELF_SETUPS, keepSetup, revertSetup, shelfValues, trySetup, type SetupId, type Shelf } from "./setupShelf";
import { Faces } from "./walkLook";

/** The looks of the screen (the gallery's variant switch): `preview` ships. */
export type MakeItYoursLook = "preview" | "segmented" | "form" | "cards" | "rows";
export const DEFAULT_MAKE_IT_YOURS_LOOK: MakeItYoursLook = "preview";

const WORK_STYLES: readonly WorkStyle[] = ["gui", "terminal"];
const WORK_KEYS: Record<WorkStyle, { title: string; detail: string }> = {
  gui: {
    title: "onboarding.makeItYours.work.gui",
    detail: "onboarding.makeItYours.work.gui.detail",
  },
  terminal: {
    title: "onboarding.makeItYours.work.terminal",
    detail: "onboarding.makeItYours.work.terminal.detail",
  },
};
// Where a new chat runs (c-8f5f7ff8b3): Cloud named on the one screen every new person sees. This
// Mac stays the default.
const RUN_INS: readonly ChatsRunIn[] = ["local", "cloud"];
const RUN_IN_KEYS: Record<ChatsRunIn, { title: string; detail: string }> = {
  local: { title: "onboarding.makeItYours.runIn.local", detail: "onboarding.makeItYours.runIn.local.detail" },
  cloud: { title: "onboarding.makeItYours.runIn.cloud", detail: "onboarding.makeItYours.runIn.cloud.detail" },
};
const MATERIAL_KEYS: Record<MakeItYoursMaterial, string> = {
  none: "onboarding.makeItYours.material.none",
  frosted: "onboarding.makeItYours.material.frosted",
  glass: "onboarding.makeItYours.material.glass",
  "glass-clear": "onboarding.makeItYours.material.glass-clear",
};

/** The value a radio carries for no background (an input's value is a string). */
const NO_BACKGROUND = "";
/** The Opacity slider's step, as Settings' row. */
const OPACITY_STEP = 0.05;

const percent = (value: number) => `${Math.round(value * 100)}%`;

/** Opacity, as Settings' row: a drag previews in the slider and is written once on release (the host
 * takes one write per click or key); an arrow key writes its step at once. A value sent shows until the
 * host's state answers it, so the thumb never jumps back and two quick keys step twice. */
function OpacitySlider({ value, label, disabled }: { value: number; label: string; disabled: boolean }) {
  const { store } = useOnboarding();
  const [drag, setDrag] = useState<number | null>(null);
  // The value sent while the host still shows `base`.
  const [sent, setSent] = useState<{ value: number; base: number } | null>(null);
  const dragging = useRef(false);
  const pending = useRef<number | null>(null);
  const current = sent !== null && sent.base === value ? sent.value : value;
  const send = (next: number) => {
    if (next === current) return;
    setSent({ value: next, base: value });
    store.call("cmux.onboarding.makeItYours.opacity", { value: next });
  };
  const release = () => {
    if (!dragging.current) return;
    dragging.current = false;
    const next = pending.current;
    pending.current = null;
    setDrag(null);
    if (next !== null) send(next);
  };
  const shown = drag ?? current;
  return (
    <div className="onb-make-adjust-row">
      <span className="onb-make-adjust-label" id="onb-make-opacity-label">
        {label}
      </span>
      <span className="onb-make-slider-cell">
        <input
          type="range"
          className="onb-make-slider"
          min={0}
          max={1}
          step={OPACITY_STEP}
          value={shown}
          aria-labelledby="onb-make-opacity-label"
          aria-valuetext={percent(shown)}
          disabled={disabled}
          onPointerDown={() => {
            dragging.current = true;
          }}
          onChange={(event) => {
            const next = Number(event.currentTarget.value);
            if (dragging.current) {
              pending.current = next;
              setDrag(next);
              return;
            }
            // A key (or an assistive app's step): its own gesture, written now.
            send(next);
          }}
          onPointerUp={release}
          onPointerCancel={release}
          onLostPointerCapture={release}
          onBlur={release}
        />
        <span className="onb-make-adjust-value" aria-hidden="true">
          {percent(shown)}
        </span>
      </span>
    </div>
  );
}

/** The intro walk's writes: one op, one publish. */
function useWalk() {
  const { store } = useOnboarding();
  return (writes: WalkWrite[]) => {
    if (writes.length > 0) store.call("cmux.onboarding.makeItYours.walk", { writes });
  };
}

const PERMISSION_KEYS = {
  ask: "onboarding.makeItYours.permission.ask",
  standard: "onboarding.makeItYours.permission.standard",
  fullAccess: "onboarding.makeItYours.permission.fullAccess",
} as const;
const NOISE_KEYS = {
  quiet: "onboarding.makeItYours.noise.quiet",
  banners: "onboarding.makeItYours.noise.banners",
  bannersSound: "onboarding.makeItYours.noise.bannersSound",
} as const;

/** Screen 1: the five look tiles (House, what the person has, first) and Tidy, off unless already set. */
function LookScreen({ opened, current }: { opened: WalkValues; current: WalkValues }) {
  const { strings } = useOnboarding();
  const walk = useWalk();
  const picked = pickedBundle(opened, current);
  const pickedName = LOOK_BUNDLES.find((bundle) => bundle.id === picked);
  const tidy = tidyOn(current);
  return (
    <>
      <fieldset className="onb-make-group onb-walk" data-screen="look" data-layout="grid">
        <legend className="onb-make-label">
          {strings.t("onboarding.makeItYours.look.label")}
          {pickedName && (
            <span className="onb-make-label-value" aria-hidden="true">
              {strings.t(pickedName.nameKey)}
            </span>
          )}
        </legend>
        <div className="onb-walk-looks">
          {LOOK_BUNDLES.map((bundle) => {
            const checked = bundle.id === picked;
            return (
              <label key={bundle.id} className="onb-make-option onb-walk-look" data-checked={checked || undefined}>
                <input
                  type="radio"
                  name="look"
                  value={bundle.id}
                  aria-label={strings.t(bundle.nameKey)}
                  aria-description={strings.t(bundle.lineKey)}
                  checked={checked}
                  onChange={() => walk(bundleWrites(bundle, opened, current))}
                />
                <Faces bundle={bundle} />
                <span className="onb-walk-look-text">
                  <span className="onb-walk-look-name">{strings.t(bundle.nameKey)}</span>
                  <span className="onb-walk-line">{strings.t(bundle.lineKey)}</span>
                </span>
              </label>
            );
          })}
        </div>
      </fieldset>
      <div className="onb-make-group onb-walk-tidy">
        <span className="onb-make-option-text">
          <span className="onb-make-option-title" id="onb-walk-tidy-label">
            {strings.t("onboarding.makeItYours.tidy")}
          </span>
          <span className="onb-make-option-detail">{strings.t("onboarding.makeItYours.tidy.detail")}</span>
        </span>
        <Switch
          size="sm"
          checked={tidy}
          aria-labelledby="onb-walk-tidy-label"
          onCheckedChange={(on: boolean) => walk(tidyWrites(on, opened, current))}
        />
      </div>
    </>
  );
}

/** `experiments.setupShelf` (off by default): the four setups, each with Try, then Keep or Revert.
 * The shelf's trials live on the page (setupShelf.ts); each click is one walk op, one publish. */
function SetupShelf({ choices }: { choices: MakeItYoursState }) {
  const { strings } = useOnboarding();
  const walk = useWalk();
  const [shelf, setShelf] = useState<Shelf>({});
  const current = shelfValues(choices);
  const run = (next: { shelf: Shelf; writes: WalkWrite[] }) => {
    setShelf(next.shelf);
    walk(next.writes);
  };
  return (
    <fieldset className="onb-make-group onb-setups" aria-describedby="onb-setups-detail">
      <legend className="onb-make-label">{strings.t("onboarding.makeItYours.setups.label")}</legend>
      <p className="onb-make-option-detail onb-setups-detail" id="onb-setups-detail">
        {strings.t("onboarding.makeItYours.setups.detail")}
      </p>
      <ul className="onb-setups-list">
        {SHELF_SETUPS.map((setup) => {
          const entry = shelf[setup.id];
          const id: SetupId = setup.id;
          const name = strings.t(setup.nameKey);
          return (
            <li key={id} className="onb-setups-row" data-setup={id} data-status={entry?.status}>
              <span className="onb-make-option-text">
                <span className="onb-make-option-title">{name}</span>
                <span className="onb-make-option-detail">{strings.t(setup.lineKey)}</span>
              </span>
              <span className="onb-setups-actions">
                {entry == null && (
                  <Button
                    size="sm"
                    aria-label={`${strings.t("onboarding.makeItYours.setups.try")} ${name}`}
                    onClick={() => run(trySetup(shelf, id, current))}
                  >
                    {strings.t("onboarding.makeItYours.setups.try")}
                  </Button>
                )}
                {entry?.status === "trying" && (
                  <>
                    <Button
                      size="sm"
                      variant="ghost"
                      aria-label={`${strings.t("onboarding.makeItYours.setups.revert")} ${name}`}
                      onClick={() => run(revertSetup(shelf, id, current))}
                    >
                      {strings.t("onboarding.makeItYours.setups.revert")}
                    </Button>
                    <Button
                      size="sm"
                      aria-label={`${strings.t("onboarding.makeItYours.setups.keep")} ${name}`}
                      onClick={() => setShelf(keepSetup(shelf, id))}
                    >
                      {strings.t("onboarding.makeItYours.setups.keep")}
                    </Button>
                  </>
                )}
                {entry?.status === "kept" && (
                  <span className="onb-make-option-detail" role="status">
                    {strings.t("onboarding.makeItYours.setups.kept")}
                  </span>
                )}
              </span>
            </li>
          );
        })}
      </ul>
    </fieldset>
  );
}

/** Screen 3: how much agents may do (each mode explained; Full Access, as cmux ships, preselected on a
 * new Mac) and how loudly cmux tells you, each as radios with their line. */
function TrustScreen({ opened, current }: { opened: WalkValues; current: WalkValues }) {
  const { strings } = useOnboarding();
  const walk = useWalk();
  const mode = permission(current);
  const loud = noise(current);
  return (
    <>
      <fieldset className="onb-make-group onb-make-work" data-screen="trust">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.permission.label")}</legend>
        <div className="onb-make-options">
          {PERMISSIONS.map((value) => (
            <label key={value} className="onb-make-option" data-checked={mode === value || undefined}>
              <input
                type="radio"
                name="permission"
                value={value}
                aria-label={strings.t(PERMISSION_KEYS[value])}
                checked={mode === value}
                onChange={() => walk(permissionWrites(value, opened, current))}
              />
              <span className="onb-make-option-text">
                <span className="onb-make-option-title">{strings.t(PERMISSION_KEYS[value])}</span>
                <span className="onb-make-option-detail">{strings.t(`${PERMISSION_KEYS[value]}.line`)}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>
      <fieldset className="onb-make-group onb-make-work">
        <legend className="onb-make-label">{strings.t("onboarding.makeItYours.noise.label")}</legend>
        <div className="onb-make-options">
          {NOISES.map((value) => (
            <label key={value} className="onb-make-option" data-checked={loud === value || undefined}>
              <input
                type="radio"
                name="noise"
                value={value}
                aria-label={strings.t(NOISE_KEYS[value])}
                checked={loud === value}
                onChange={() => walk(noiseWrites(value, opened, current))}
              />
              <span className="onb-make-option-text">
                <span className="onb-make-option-title">{strings.t(NOISE_KEYS[value])}</span>
                <span className="onb-make-option-detail">{strings.t(`${NOISE_KEYS[value]}.line`)}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>
    </>
  );
}

/** Looks whose tiles carry no name: the chosen work's full name shows once, under the row or the
 * preview, instead of six names cut to a word each. */
const CAPTIONED: ReadonlySet<MakeItYoursLook> = new Set(["preview", "segmented", "form"]);

export function MakeItYoursStep({
  choices,
  look = DEFAULT_MAKE_IT_YOURS_LOOK,
  screen = "all",
  opened,
}: {
  choices: MakeItYoursState | null | undefined;
  look?: MakeItYoursLook;
  /** The walk's screen shown; "all": today's one screen (experiments.introWalk off). */
  screen?: MakeItYoursScreen | "all";
  /** The settings when the step opened (what House and the rows' "as before" write back); absent: now. */
  opened?: WalkValues | null;
}) {
  const { strings, store } = useOnboarding();
  if (choices == null) return null;
  const current = walkValues(choices);
  if (screen === "look" || screen === "trust") {
    const Screen = screen === "look" ? LookScreen : TrustScreen;
    return (
      <div className="onb-make" data-look={look} data-screen={screen}>
        <Screen opened={opened ?? current} current={current} />
      </div>
    );
  }
  // Screen 2 asks only how you work; screen 4 (Tune) only density and the background rows.
  const askWork = screen === "all" || screen === "work";
  const askTune = screen === "all" || screen === "tune";
  const walkScreen = screen === "all" ? undefined : screen;
  const backgrounds: MakeItYoursBackground[] = [{ id: NO_BACKGROUND, name: "", preview: null }, ...choices.backgrounds];
  const backgroundLabel = (id: string, name: string) =>
    id === NO_BACKGROUND
      ? strings.t("onboarding.makeItYours.background.none")
      : id === "daily"
        ? strings.t("onboarding.makeItYours.background.shuffle")
        : name;
  const chosenId = choices.background ?? NO_BACKGROUND;
  const chosen = backgrounds.find((background) => background.id === chosenId) ?? backgrounds[0];
  const chosenLabel = backgroundLabel(chosen.id, chosen.name);
  const captioned = CAPTIONED.has(look);
  // The preview names the work under itself; the other captioned looks name it under the tiles.
  const tileCaption = captioned && look !== "preview";
  // Opacity and Material only change a picture: with None they stay in place, dimmed and inert.
  const noPicture = chosenId === NO_BACKGROUND;

  const work = (
    <Group look={look} className="onb-make-work" label={strings.t("onboarding.makeItYours.work.label")}>
      <div className="onb-make-options">
        {WORK_STYLES.map((style) => (
          <label key={style} className="onb-make-option" data-checked={choices.workStyle === style || undefined}>
            <input
              type="radio"
              name="workStyle"
              value={style}
              aria-label={strings.t(WORK_KEYS[style].title)}
              checked={choices.workStyle === style}
              onChange={() =>
                store.call("cmux.onboarding.makeItYours.workStyle", {
                  value: style,
                })
              }
            />
            {look === "preview" && <span className="onb-make-option-mark" aria-hidden="true" />}
            <span className="onb-make-option-text">
              <span className="onb-make-option-title">
                {strings.t(WORK_KEYS[style].title)}
                {style === "gui" && (
                  <span className="onb-make-badge">{strings.t("onboarding.makeItYours.recommended")}</span>
                )}
              </span>
              <span className="onb-make-option-detail">{strings.t(WORK_KEYS[style].detail)}</span>
            </span>
          </label>
        ))}
      </div>
    </Group>
  );
  // An older host sends no `chatsRunIn`: no row.
  const runIn =
    choices.chatsRunIn == null ? null : (
      <Group look={look} className="onb-make-run-in" label={strings.t("onboarding.makeItYours.runIn.label")}>
        <div
          className="onb-make-segments ui-slide-host"
          style={{ "--onb-make-count": RUN_INS.length } as CSSProperties}
        >
          <SlidingIndicator selected={choices.chatsRunIn} selector="[data-checked]" className="onb-make-thumb" />
          {RUN_INS.map((where) => (
            <label
              key={where}
              className="onb-make-segment ui-slide-item"
              data-checked={choices.chatsRunIn === where || undefined}
            >
              <input
                type="radio"
                name="chatsRunIn"
                value={where}
                aria-label={strings.t(RUN_IN_KEYS[where].title)}
                aria-describedby="onb-make-run-in-detail"
                checked={choices.chatsRunIn === where}
                onChange={() => store.call("cmux.onboarding.makeItYours.chatsRunIn", { value: where })}
              />
              <span>{strings.t(RUN_IN_KEYS[where].title)}</span>
            </label>
          ))}
        </div>
        {/* Every location's sentence sits in the one cell, only the chosen one shown, so a pick never
            moves the rows under it (intro walk: 14 px when the two sentences wrapped differently). */}
        <p id="onb-make-run-in-detail" className="onb-make-option-detail onb-make-run-in-detail">
          {RUN_INS.filter((where) => where !== choices.chatsRunIn).map((where) => (
            <span
              key={where}
              className="onb-make-run-in-detail__size"
              aria-hidden="true"
              data-label={strings.t(RUN_IN_KEYS[where].detail)}
            />
          ))}
          <span>{strings.t(RUN_IN_KEYS[choices.chatsRunIn].detail)}</span>
        </p>
      </Group>
    );
  const density = (
    <Group look={look} className="onb-make-density" label={strings.t("onboarding.makeItYours.density.label")}>
      <div
        className="onb-make-segments ui-slide-host"
        style={{ "--onb-make-count": choices.densities.length } as CSSProperties}
      >
        <SlidingIndicator selected={choices.density} selector="[data-checked]" className="onb-make-thumb" />
        {choices.densities.map((item) => (
          <label
            key={item.id}
            className="onb-make-segment ui-slide-item"
            data-checked={choices.density === item.id || undefined}
          >
            <input
              type="radio"
              name="density"
              value={item.id}
              aria-label={item.name}
              checked={choices.density === item.id}
              onChange={() =>
                store.call("cmux.onboarding.makeItYours.density", {
                  value: item.id,
                })
              }
            />
            <span>{item.name}</span>
          </label>
        ))}
      </div>
    </Group>
  );
  const background = (
    <Group look={look} className="onb-make-background" label={strings.t("onboarding.makeItYours.background.label")}>
      <div className="onb-make-tiles">
        {backgrounds.map((item) => {
          const label = backgroundLabel(item.id, item.name);
          const checked = chosenId === item.id;
          return (
            <label
              key={item.id || "none"}
              className="onb-make-tile"
              data-checked={checked || undefined}
              // tooltip-allow: a picture tile; only the cards look names it beside the picture.
              title={look === "cards" ? undefined : label}
            >
              <input
                type="radio"
                name="background"
                value={item.id}
                aria-label={label}
                checked={checked}
                onChange={() =>
                  store.call("cmux.onboarding.makeItYours.background", {
                    id: item.id === NO_BACKGROUND ? null : item.id,
                  })
                }
              />
              <HostIcon
                image={item.preview}
                className={cx("onb-make-tile-image", item.id === NO_BACKGROUND && "is-none")}
              />
              {look === "cards" && <span className="onb-make-tile-name">{label}</span>}
            </label>
          );
        })}
      </div>
      {tileCaption && (
        <p className="onb-make-caption" aria-hidden="true">
          {chosenLabel}
        </p>
      )}
      <div className="onb-make-adjust" data-off={noPicture || undefined}>
        {choices.opacity !== null && (
          <OpacitySlider
            value={choices.opacity}
            label={strings.t("onboarding.makeItYours.opacity")}
            disabled={noPicture}
          />
        )}
        <div className="onb-make-adjust-row" role="radiogroup" aria-labelledby="onb-make-material-label">
          <span className="onb-make-adjust-label" id="onb-make-material-label">
            {strings.t("onboarding.makeItYours.material")}
          </span>
          <div className="onb-make-chips ui-slide-host">
            <SlidingIndicator selected={choices.material} selector="[data-checked]" className="onb-make-thumb" />
            {choices.materials.map((material) => (
              <label
                key={material}
                className="onb-make-chip ui-slide-item"
                data-checked={choices.material === material || undefined}
              >
                <input
                  type="radio"
                  name="material"
                  value={material}
                  aria-label={strings.t(MATERIAL_KEYS[material])}
                  checked={choices.material === material}
                  disabled={noPicture}
                  onChange={() =>
                    store.call("cmux.onboarding.makeItYours.material", {
                      value: material,
                    })
                  }
                />
                <span>{strings.t(MATERIAL_KEYS[material])}</span>
              </label>
            ))}
          </div>
        </div>
      </div>
    </Group>
  );

  // The setups shelf leads today's one screen and the walk's How you work (experiments.setupShelf).
  const shelf = askWork && choices.setupShelf === true ? <SetupShelf choices={choices} /> : null;

  // The walk shows the preview on Tune, where the picks it draws are made; screen 2 has no stage.
  if (look === "preview" && askTune) {
    return (
      <div className="onb-make" data-look={look} data-screen={walkScreen}>
        <figure className="onb-make-stage" aria-hidden="true">
          <MakeItYoursPreview choices={choices} image={chosen.preview} />
          <figcaption className="onb-make-caption">{chosenLabel}</figcaption>
        </figure>
        <div className="onb-make-choices">
          {shelf}
          {askWork && work}
          {askWork && runIn}
          {density}
          {background}
        </div>
      </div>
    );
  }
  return (
    <div className="onb-make" data-look={look} data-screen={walkScreen}>
      {shelf}
      {askWork && work}
      {askWork && runIn}
      {askTune && density}
      {askTune && background}
    </div>
  );
}

/** One choice: a fieldset with its question. The form look sets the question beside the control. */
function Group({
  look,
  className,
  label,
  children,
}: {
  look: MakeItYoursLook;
  className: string;
  label: string;
  children: ReactNode;
}) {
  return (
    <fieldset className={cx("onb-make-group", className)}>
      <legend className="onb-make-label">{label}</legend>
      {look === "form" ? <div className="onb-make-control">{children}</div> : children}
    </fieldset>
  );
}

/** A small cmux window drawn from the answers: the painting behind glass panes, a sidebar, and a
 * chat beside a browser (Agents First) or one terminal (Terminal First). Density sets the rows'
 * spacing through `data-density`; nothing here measures or animates on its own. */
function MakeItYoursPreview({
  choices,
  image,
}: {
  choices: MakeItYoursState;
  image: MakeItYoursBackground["preview"];
}) {
  const gui = choices.workStyle === "gui";
  return (
    <div
      className="onb-make-window"
      data-density={choices.density}
      data-work={choices.workStyle}
      data-art={image != null || undefined}
    >
      <HostIcon image={image} className={cx("onb-make-window-art", image == null && "is-none")} />
      <div className="onb-make-window-bar">
        <span />
        <span />
        <span />
      </div>
      <div className="onb-make-window-body">
        <div className="onb-make-pane onb-make-pane-side">
          {[0, 1, 2, 3, 4].map((row) => (
            <span key={row} className="onb-make-line" data-on={row === 1 || undefined} />
          ))}
        </div>
        {gui ? (
          <>
            <div className="onb-make-pane onb-make-pane-chat">
              <span className="onb-make-bubble is-mine" />
              <span className="onb-make-line" />
              <span className="onb-make-line is-short" />
              <span className="onb-make-bubble is-mine" />
              <span className="onb-make-line" />
              <span className="onb-make-composer" />
            </div>
            <div className="onb-make-pane onb-make-pane-web">
              <span className="onb-make-block" />
              <span className="onb-make-line" />
              <span className="onb-make-line is-short" />
            </div>
          </>
        ) : (
          <div className="onb-make-pane onb-make-pane-term">
            {[0, 1, 2, 3, 4, 5].map((row) => (
              <span
                key={row}
                className={cx("onb-make-line", row % 3 === 0 && "is-prompt", row % 3 === 2 && "is-short")}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
