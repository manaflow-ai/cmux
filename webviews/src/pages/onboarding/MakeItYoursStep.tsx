// Make cmux Yours (cmux#48416): a new person's one setup screen, four choices, each already on the
// recommended answer so Continue alone is a good setup:
//   1. How you work: Agents first (recommended; Cmd-T opens the New Tab page, where a chat starts) or
//      Terminal first (Cmd-T opens a terminal). The words never say "classic".
//   2. Where chats run: This Mac (the default) or Cloud (`agentPane.newChatsIn`), each with one caption.
//   3. Density: Compact, Standard or Comfortable (Settings has the two extremes).
//   4. Background: None, Shuffle Paintings or one of a few built-in works.
// No theme row: windows follow macOS's light or dark mode, and the terminal theme stays in Settings.
// Each choice is a group of native radios (the browser owns roles, arrows and focus); a pick is sent
// at once and the host writes it, so the app behind the window changes while the person watches.
// Return presses Continue, Escape skips (the page's own key handler).
//
// The `preview` look (the one that ships) also draws a small cmux window built from the three
// answers: the painting behind it, a chat or a terminal in it, its rows as tight as the density.
// The onboarding window covers the app it changes, so this is where a pick is seen. It is drawn from
// the state alone and is hidden from assistive tech: the radios carry every answer.
import type { ReactNode } from "react";
import { cx } from "../../ui/cx";
import type { ChatsRunIn, DensityChoice, MakeItYoursBackground, MakeItYoursState, WorkStyle } from "./ops";
import { HostIcon, useOnboarding } from "./parts";

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
// Where a new chat runs (c-8f5f7ff8b3): Cloud named on the one screen every new person sees, so a
// Mac with no agent installed still has a way to start. This Mac stays the default.
const RUN_INS: readonly ChatsRunIn[] = ["local", "cloud"];
const RUN_IN_KEYS: Record<ChatsRunIn, { title: string; detail: string }> = {
  local: { title: "onboarding.makeItYours.runIn.local", detail: "onboarding.makeItYours.runIn.local.detail" },
  cloud: { title: "onboarding.makeItYours.runIn.cloud", detail: "onboarding.makeItYours.runIn.cloud.detail" },
};
const DENSITIES: readonly DensityChoice[] = ["compact", "standard", "comfortable"];
const DENSITY_KEYS: Record<DensityChoice, string> = {
  compact: "onboarding.makeItYours.density.compact",
  standard: "onboarding.makeItYours.density.standard",
  comfortable: "onboarding.makeItYours.density.comfortable",
};

/** The value a radio carries for no background (an input's value is a string). */
const NO_BACKGROUND = "";

/** Looks whose tiles carry no name: the chosen work's full name shows once, under the row or the
 * preview, instead of six names cut to a word each. */
const CAPTIONED: ReadonlySet<MakeItYoursLook> = new Set(["preview", "segmented", "form"]);

export function MakeItYoursStep({
  choices,
  look = DEFAULT_MAKE_IT_YOURS_LOOK,
}: {
  choices: MakeItYoursState | null | undefined;
  look?: MakeItYoursLook;
}) {
  const { strings, store } = useOnboarding();
  if (choices == null) return null;
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
              onChange={() => store.call("cmux.onboarding.makeItYours.workStyle", { value: style })}
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
        <div className="onb-make-segments" data-count={RUN_INS.length}>
          {RUN_INS.map((where) => (
            <label key={where} className="onb-make-segment" data-checked={choices.chatsRunIn === where || undefined}>
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
        <p id="onb-make-run-in-detail" className="onb-make-option-detail onb-make-run-in-detail">
          {strings.t(RUN_IN_KEYS[choices.chatsRunIn].detail)}
        </p>
      </Group>
    );
  const density = (
    <Group look={look} className="onb-make-density" label={strings.t("onboarding.makeItYours.density.label")}>
      <div className="onb-make-segments">
        {DENSITIES.map((value) => (
          <label key={value} className="onb-make-segment" data-checked={choices.density === value || undefined}>
            <input
              type="radio"
              name="density"
              value={value}
              aria-label={strings.t(DENSITY_KEYS[value])}
              checked={choices.density === value}
              onChange={() => store.call("cmux.onboarding.makeItYours.density", { value })}
            />
            <span>{strings.t(DENSITY_KEYS[value])}</span>
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
    </Group>
  );

  if (look === "preview") {
    return (
      <div className="onb-make" data-look={look}>
        <figure className="onb-make-stage" aria-hidden="true">
          <MakeItYoursPreview choices={choices} image={chosen.preview} />
          <figcaption className="onb-make-caption">{chosenLabel}</figcaption>
        </figure>
        <div className="onb-make-choices">
          {work}
          {runIn}
          {density}
          {background}
        </div>
      </div>
    );
  }
  return (
    <div className="onb-make" data-look={look}>
      {work}
      {runIn}
      {density}
      {background}
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
