// Switch Automatically (Leo, 2026-11-14: "the auto switching that macos does ... for this app"): Off,
// Light & Dark, Time of Day, Sun (a macOS dynamic wallpaper) or Rotate, each with its own small
// editor. It sits under the Background card's first tile row, so opening an editor never moves the
// picker grid; the model (which mode the values mean, what a mode writes) is ../wallpaperSwitch.ts.
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { Button } from "../../../ui/Button";
import { Select } from "../editors/Select";
import { t } from "../strings";
import {
  dynamicChoices,
  FOLDER_PREFIX,
  formatWhen,
  isFixed,
  modeOf,
  MODES,
  nextWhen,
  OFFSETS,
  parseWhen,
  renameWhen,
  SCHEDULE_KEY,
  SHUFFLE_PAINTINGS,
  SUN_EVENTS,
  BACKGROUND_KEY,
  LIGHT_KEY,
  DARK_KEY,
  typicalMinutes,
  withEntry,
  writesFor,
  type PictureChoice,
  type SunEvent,
  type When,
  type WallpaperMode,
  type WallpaperValues,
  type WallpaperWrite,
} from "../wallpaperSwitch";

/** segmented: one row of modes, the editor under it (shipped). menu: one menu and a summary line.
 * timeline: the segmented row, and Time of Day drawn as a strip of the day. */
export type WallpaperSwitchDesign = "segmented" | "menu" | "timeline";

export type WallpaperSwitchProps = {
  values: WallpaperValues;
  /** Fixed pictures a slot can hold (none, the desktop picture, art, macOS and your images). */
  choices: readonly PictureChoice[];
  location: string | null;
  /** Your Images' folder, once there are some (Rotate offers it). */
  yoursFolder: string | null;
  design?: WallpaperSwitchDesign;
  disabled?: boolean;
  /** One undoable step: each write a value, or null to reset the key. */
  onWrite: (writes: WallpaperWrite[], label?: string) => unknown;
  onLocation: (value: string | null) => unknown;
  onChooseFolder: () => unknown;
  /** The Change Picture row (appearance.backgroundRotation), drawn in Rotate's editor. */
  rotation?: ReactNode;
};

const MODE_TITLE: Record<WallpaperMode, string> = {
  off: "settingsWindow.wallpaperSwitch.off",
  appearance: "settingsWindow.wallpaperSwitch.appearance",
  schedule: "settingsWindow.wallpaperSwitch.schedule",
  sun: "settingsWindow.wallpaperSwitch.sun",
  rotate: "settingsWindow.wallpaperSwitch.rotate",
};
const EVENT_TITLE: Record<string, string> = {
  time: "settingsWindow.wallpaperSwitch.atTime",
  dawn: "settingsWindow.wallpaperSwitch.dawn",
  sunrise: "settingsWindow.wallpaperSwitch.sunrise",
  noon: "settingsWindow.wallpaperSwitch.noon",
  sunset: "settingsWindow.wallpaperSwitch.sunset",
  dusk: "settingsWindow.wallpaperSwitch.dusk",
};
const LOCATION = /^\s*-?\d{1,2}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?\s*$/;

const thumbSrc = (id: string) => `backdrop/${encodeURIComponent(encodeURIComponent(id))}`;

function offsetTitle(minutes: number): string {
  if (minutes === 0) return t("settingsWindow.wallpaperSwitch.atEvent");
  return t(
    minutes < 0 ? "settingsWindow.wallpaperSwitch.minutesBefore" : "settingsWindow.wallpaperSwitch.minutesAfter",
    Math.abs(minutes),
  );
}

function whenTitle(when: When): string {
  if (when.kind === "time") return formatWhen(when);
  const event = t(EVENT_TITLE[when.event]!);
  return when.offset === 0 ? event : `${event} ${offsetTitle(when.offset)}`;
}

function pictureTitle(id: string | null, choices: readonly PictureChoice[]): string {
  if (id === null) return t("settingsWindow.wallpaperSwitch.sameAsOther");
  if (id === "none") return t("settingsWindow.backdropPicker.none");
  return (
    choices.find((choice) => choice.id === id)?.title ??
    id
      .replace(/^(system|file):/, "")
      .split("/")
      .at(-1) ??
    id
  );
}

function Thumb({ id }: { id: string | null }) {
  const [failed, setFailed] = useState<string | null>(null);
  if (id === null || id === "none" || failed === id) return <span className="backdrop-thumb backdrop-none" />;
  return <img className="backdrop-thumb" alt="" src={thumbSrc(id)} onError={() => setFailed(id)} />;
}

/** A picture slot: its thumbnail and title; a click opens the picture list under the editor. */
function Slot({
  label,
  value,
  choices,
  open,
  disabled,
  onToggle,
}: {
  label: string;
  value: string | null;
  choices: readonly PictureChoice[];
  open: boolean;
  disabled: boolean;
  onToggle: () => void;
}) {
  const title = pictureTitle(value, choices);
  return (
    <button
      type="button"
      className="backdrop-tile wallpaper-slot"
      aria-expanded={open}
      aria-label={t("settingsWindow.wallpaperSwitch.choosePicture", label, title)}
      disabled={disabled}
      onClick={onToggle}
    >
      <span className="backdrop-frame">
        <Thumb id={value} />
      </span>
      <span className="row-help wallpaper-slot-label">{label}</span>
      <span className="backdrop-title">{title}</span>
    </button>
  );
}

/** The pictures a slot can take, the card's tiles at a smaller size; the slot's picture is pressed. */
function SlotPicker({
  value,
  choices,
  onPick,
}: {
  value: string | null;
  choices: readonly PictureChoice[];
  onPick: (id: string) => void;
}) {
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div className="backdrop-grid wallpaper-slot-picker" role="group">
      {choices.map((choice) => (
        <button
          type="button"
          key={choice.id}
          className="backdrop-tile"
          aria-pressed={value === choice.id}
          aria-label={choice.title}
          onClick={() => onPick(choice.id)}
        >
          <span className="backdrop-frame">
            <Thumb id={choice.id} />
          </span>
          <span className="backdrop-title">{choice.title}</span>
        </button>
      ))}
    </div>
  );
}

function LocationField({
  value,
  disabled,
  onSave,
}: {
  value: string | null;
  disabled: boolean;
  onSave: (v: string | null) => unknown;
}) {
  const id = useId();
  // What the person is typing; null shows the saved value (a change from elsewhere shows at once).
  const [draft, setDraft] = useState<string | null>(null);
  const [invalid, setInvalid] = useState(false);
  const commit = () => {
    if (draft === null) return;
    const next = draft.trim();
    if (next !== "" && !LOCATION.test(next)) return setInvalid(true);
    setInvalid(false);
    setDraft(null);
    const saved = next === "" ? null : next.replace(/\s+/g, "");
    if (saved !== value) void onSave(saved);
  };
  return (
    <div className="wallpaper-line">
      <label className="row-help" htmlFor={id}>
        {t("settingsWindow.wallpaperSwitch.location")}
      </label>
      <input
        id={id}
        className="field wallpaper-location"
        aria-label={t("settingsWindow.wallpaperSwitch.location")}
        type="text"
        inputMode="decimal"
        spellCheck={false}
        value={draft ?? value ?? ""}
        disabled={disabled}
        aria-invalid={invalid || undefined}
        placeholder={t("settingsWindow.wallpaperSwitch.locationAuto")}
        onChange={(event) => setDraft(event.currentTarget.value)}
        onBlur={commit}
        onKeyDown={(event) => event.key === "Enter" && commit()}
      />
      {invalid && <span className="row-help field-error">{t("settingsWindow.wallpaperSwitch.locationInvalid")}</span>}
    </div>
  );
}

/** One row of Time of Day: when (a time, or a sun event with an offset), its picture, Remove. */
function ScheduleRow({
  when,
  picture,
  choices,
  open,
  disabled,
  onWhen,
  onToggle,
  onRemove,
}: {
  when: string;
  picture: string;
  choices: readonly PictureChoice[];
  open: boolean;
  disabled: boolean;
  onWhen: (next: string) => void;
  onToggle: () => void;
  onRemove: (() => void) | null;
}) {
  const kindId = useId();
  const offsetId = useId();
  const parsed = parseWhen(when) ?? { kind: "time" as const, minutes: 0 };
  const kind = parsed.kind === "time" ? "time" : parsed.event;
  return (
    <div className="wallpaper-when" data-when={when}>
      <span id={kindId} hidden>
        {t("settingsWindow.wallpaperSwitch.when")}
      </span>
      <Select
        value={kind}
        disabled={disabled}
        labelId={kindId}
        onChange={(next) =>
          onWhen(
            formatWhen(
              next === "time"
                ? { kind: "time", minutes: typicalMinutes(parsed) }
                : { kind: "sun", event: next as SunEvent, offset: 0 },
            ),
          )
        }
      >
        <option value="time">{t(EVENT_TITLE.time!)}</option>
        {SUN_EVENTS.map((event) => (
          <option key={event} value={event}>
            {t(EVENT_TITLE[event]!)}
          </option>
        ))}
      </Select>
      {parsed.kind === "time" ? (
        <input
          className="field wallpaper-time"
          type="time"
          aria-label={t("settingsWindow.wallpaperSwitch.time")}
          value={formatWhen(parsed)}
          disabled={disabled}
          onChange={(event) => {
            const next = parseWhen(event.currentTarget.value);
            if (next) onWhen(formatWhen(next));
          }}
        />
      ) : (
        <>
          <span id={offsetId} hidden>
            {t("settingsWindow.wallpaperSwitch.offset")}
          </span>
          <Select
            value={String(parsed.offset)}
            disabled={disabled}
            labelId={offsetId}
            onChange={(next) => onWhen(formatWhen({ ...parsed, offset: Number(next) }))}
          >
            {[...new Set([...OFFSETS, parsed.offset])]
              .sort((a, b) => a - b)
              .map((minutes) => (
                <option key={minutes} value={String(minutes)}>
                  {offsetTitle(minutes)}
                </option>
              ))}
          </Select>
        </>
      )}
      <Slot
        label={whenTitle(parsed)}
        value={picture}
        choices={choices}
        open={open}
        disabled={disabled}
        onToggle={onToggle}
      />
      {onRemove && (
        <Button
          variant="ghost"
          size="sm"
          icon
          type="button"
          className="icon-button"
          aria-label={t("settingsWindow.wallpaperSwitch.remove", whenTitle(parsed))}
          disabled={disabled}
          onClick={onRemove}
        >
          ×
        </Button>
      )}
    </div>
  );
}

/** The day as a strip: each scheduled picture's thumbnail from where it starts (timeline design). */
function DayStrip({ schedule }: { schedule: Record<string, string> }) {
  const marks = Object.entries(schedule)
    .flatMap(([key, picture]) => {
      const when = parseWhen(key);
      return when ? [{ key, picture, at: typicalMinutes(when), title: whenTitle(when) }] : [];
    })
    .sort((a, b) => a.at - b.at);
  if (marks.length === 0) return null;
  return (
    <div className="wallpaper-strip" aria-hidden="true">
      {marks.map((mark, index) => {
        const end = marks[index + 1]?.at ?? 1440;
        return (
          <span
            key={mark.key}
            className="wallpaper-strip-span"
            style={{ left: `${(mark.at / 1440) * 100}%`, width: `${((end - mark.at) / 1440) * 100}%` }}
            title={/* tooltip-allow: the strip is decoration; the rows below say the same */ mark.title}
          >
            <Thumb id={mark.picture} />
          </span>
        );
      })}
      {/* Before the first start, yesterday's last picture shows. */}
      <span className="wallpaper-strip-span" style={{ left: 0, width: `${(marks[0]!.at / 1440) * 100}%` }}>
        <Thumb id={marks.at(-1)!.picture} />
      </span>
    </div>
  );
}

function summary(mode: WallpaperMode, values: WallpaperValues, choices: readonly PictureChoice[]): string {
  switch (mode) {
    case "appearance":
      return `${t("settingsWindow.wallpaperSwitch.light")}: ${pictureTitle(values.light, choices)} · ${t("settingsWindow.wallpaperSwitch.dark")}: ${pictureTitle(values.dark, choices)}`;
    case "schedule":
      return Object.entries(values.schedule ?? {})
        .map(([key, picture]) => {
          const when = parseWhen(key);
          return `${when ? whenTitle(when) : key}: ${pictureTitle(picture, choices)}`;
        })
        .join(" · ");
    case "sun":
      return pictureTitle(values.background, choices);
    default:
      return "";
  }
}

export function WallpaperSwitch({
  values,
  choices,
  location,
  yoursFolder,
  design = "segmented",
  disabled = false,
  onWrite,
  onLocation,
  onChooseFolder,
  rotation,
}: WallpaperSwitchProps) {
  const labelId = useId();
  const name = useId();
  const mode = modeOf(values, choices);
  // The last picture that stayed: Off puts it back after a mode that has none of its own.
  const lastFixed = useRef<string | null>(isFixed(values.background) ? values.background : null);
  useEffect(() => {
    if (isFixed(values.background)) lastFixed.current = values.background;
  }, [values.background]);
  // Which slot's picture list is open: "light", "dark", "sun" or a schedule row's key.
  // Kept with the mode it opened in, so a mode change closes it.
  const [opened, setOpened] = useState<{ mode: WallpaperMode; id: string } | null>(null);
  const slot = opened?.mode === mode ? opened.id : null;
  const setSlot = (id: string | null) => setOpened(id === null ? null : { mode, id });
  const sunPictures = dynamicChoices(choices);
  const write = (writes: WallpaperWrite[], label?: string) => (writes.length > 0 ? onWrite(writes, label) : undefined);
  const pickMode = (next: WallpaperMode) => {
    if (next === mode) return;
    write(
      writesFor(next, values, { choices, lastFixed: lastFixed.current }),
      t("settingsPage.history.change", t("settingsWindow.wallpaperSwitch.title"), t(MODE_TITLE[next])),
    );
  };
  const toggle = (id: string) => setSlot(slot === id ? null : id);
  const schedule = values.schedule ?? {};
  const setSchedule = (next: Record<string, string>) => write([[SCHEDULE_KEY, next]]);
  const modeDisabled = (item: WallpaperMode) => item === "sun" && mode !== "sun" && sunPictures.length === 0;

  const picker = (value: string | null, list: readonly PictureChoice[], pick: (id: string) => void) => (
    <SlotPicker
      value={value}
      choices={list}
      onPick={(id) => {
        setSlot(null);
        pick(id);
      }}
    />
  );

  let editor: ReactNode = null;
  if (mode === "appearance") {
    editor = (
      <>
        <div className="wallpaper-slots">
          <Slot
            label={t("settingsWindow.wallpaperSwitch.light")}
            value={values.light}
            choices={choices}
            open={slot === "light"}
            disabled={disabled}
            onToggle={() => toggle("light")}
          />
          <Slot
            label={t("settingsWindow.wallpaperSwitch.dark")}
            value={values.dark}
            choices={choices}
            open={slot === "dark"}
            disabled={disabled}
            onToggle={() => toggle("dark")}
          />
        </div>
        {slot === "light" && picker(values.light, choices, (id) => write([[LIGHT_KEY, id]]))}
        {slot === "dark" && picker(values.dark, choices, (id) => write([[DARK_KEY, id]]))}
      </>
    );
  } else if (mode === "schedule") {
    const entries = Object.entries(schedule);
    const usesSun = entries.some(([key]) => parseWhen(key)?.kind === "sun");
    editor = (
      <>
        {design === "timeline" && <DayStrip schedule={schedule} />}
        <div className="wallpaper-schedule">
          {entries.map(([key, picture]) => (
            <ScheduleRow
              key={key}
              when={key}
              picture={picture}
              choices={choices}
              open={slot === key}
              disabled={disabled}
              onWhen={(next) => {
                const renamed = renameWhen(schedule, key, next);
                if (renamed && renamed !== schedule) {
                  if (slot === key) setSlot(next);
                  setSchedule(renamed);
                }
              }}
              onToggle={() => toggle(key)}
              onRemove={
                entries.length > 1 ? () => setSchedule(Object.fromEntries(entries.filter(([k]) => k !== key))) : null
              }
            />
          ))}
        </div>
        {slot !== null &&
          slot in schedule &&
          picker(schedule[slot]!, choices, (id) => setSchedule(withEntry(schedule, slot, id)))}
        <div className="wallpaper-line">
          <Button
            type="button"
            className="button"
            disabled={disabled}
            onClick={() =>
              setSchedule(withEntry(schedule, nextWhen(schedule), values.light ?? lastFixed.current ?? "none"))
            }
          >
            {t("settingsWindow.wallpaperSwitch.addTime")}
          </Button>
        </div>
        {usesSun && <LocationField value={location} disabled={disabled} onSave={onLocation} />}
      </>
    );
  } else if (mode === "sun") {
    editor = (
      <>
        <div className="wallpaper-slots">
          <Slot
            label={t("settingsWindow.wallpaperSwitch.sun")}
            value={values.background}
            choices={choices}
            open={slot === "sun"}
            disabled={disabled}
            onToggle={() => toggle("sun")}
          />
        </div>
        {slot === "sun" && picker(values.background, sunPictures, (id) => write([[BACKGROUND_KEY, id]]))}
        <LocationField value={location} disabled={disabled} onSave={onLocation} />
      </>
    );
  } else if (mode === "rotate") {
    const folder = values.background;
    const folders = [
      { id: SHUFFLE_PAINTINGS, title: t("settingsWindow.backdropPicker.shufflePaintings") },
      ...(yoursFolder
        ? [{ id: FOLDER_PREFIX + yoursFolder, title: t("settingsWindow.backdropPicker.shuffleYours") }]
        : []),
      ...(folder.startsWith(FOLDER_PREFIX) && folder !== FOLDER_PREFIX + yoursFolder
        ? [{ id: folder, title: folder.slice(FOLDER_PREFIX.length).split("/").filter(Boolean).at(-1) ?? folder }]
        : []),
    ];
    editor = (
      <>
        <div className="wallpaper-line">
          <fieldset className="segmented" aria-label={t("settingsWindow.wallpaperSwitch.folder")} disabled={disabled}>
            {folders.map((item) => (
              <label key={item.id} className="segment" data-checked={folder === item.id ? "" : undefined}>
                <input
                  type="radio"
                  name={`${name}-folder`}
                  aria-label={item.title}
                  checked={folder === item.id}
                  onChange={() => write([[BACKGROUND_KEY, item.id]])}
                />
                {item.title}
              </label>
            ))}
          </fieldset>
          <Button type="button" className="button" disabled={disabled} onClick={() => void onChooseFolder()}>
            {t("settingsWindow.wallpaperSwitch.chooseFolder")}
          </Button>
        </div>
        {rotation}
      </>
    );
  }

  // The menu design says what the mode picked in one line; no line explains a mode.
  const line = design === "menu" ? summary(mode, values, choices) : "";
  return (
    <div className="wallpaper-switch" data-wallpaper-switch={mode} data-design={design}>
      <div className="wallpaper-line">
        <span id={labelId} className="row-title">
          {t("settingsWindow.wallpaperSwitch.title")}
        </span>
        {design === "menu" ? (
          <Select
            value={mode}
            disabled={disabled}
            labelId={labelId}
            onChange={(next) => pickMode(next as WallpaperMode)}
          >
            {MODES.map((item) => (
              <option key={item} value={item} disabled={modeDisabled(item)}>
                {t(MODE_TITLE[item])}
              </option>
            ))}
          </Select>
        ) : (
          <fieldset className="segmented" aria-labelledby={labelId} disabled={disabled}>
            {MODES.map((item) => (
              <label key={item} className="segment" data-checked={mode === item ? "" : undefined}>
                <input
                  type="radio"
                  name={name}
                  value={item}
                  aria-label={t(MODE_TITLE[item])}
                  checked={mode === item}
                  disabled={modeDisabled(item)}
                  onChange={() => pickMode(item)}
                />
                {t(MODE_TITLE[item])}
              </label>
            ))}
          </fieldset>
        )}
      </div>
      {line && <p className="row-help wallpaper-help">{line}</p>}
      {editor && <div className="wallpaper-editor">{editor}</div>}
    </div>
  );
}
