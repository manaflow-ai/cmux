// Switch Automatically (Leo, 2026-11-14: "the auto switching that macos does ... for this app"): which
// way the window background changes on its own, read from and written to the appearance keys the
// app's engine reads. The page's control (components/WallpaperSwitch.tsx) draws it; this file is the
// model, so the mode a set of values means and the writes a mode needs are one place.

export const BACKGROUND_KEY = "appearance.background";
export const LIGHT_KEY = "appearance.backgroundLight";
export const DARK_KEY = "appearance.backgroundDark";
export const SCHEDULE_KEY = "appearance.backgroundSchedule";
export const DYNAMIC_KEY = "appearance.backgroundDynamic";
export const LOCATION_KEY = "appearance.backgroundLocation";
export const ROTATION_KEY = "appearance.backgroundRotation";

/** Every key the control writes; one mode change is one undo step over all of them. */
export const WALLPAPER_KEYS: readonly string[] = [BACKGROUND_KEY, LIGHT_KEY, DARK_KEY, SCHEDULE_KEY, DYNAMIC_KEY];

/** `appearance.background` values that are modes, not pictures. */
export const FOLLOW_APPEARANCE = "appearance";
export const FOLLOW_SCHEDULE = "schedule";
export const SHUFFLE_PAINTINGS = "daily";
export const FOLDER_PREFIX = "folder:";

export type WallpaperMode = "off" | "appearance" | "schedule" | "sun" | "rotate";
export const MODES: readonly WallpaperMode[] = ["off", "appearance", "schedule", "sun", "rotate"];

export type WallpaperValues = {
  background: string;
  light: string | null;
  dark: string | null;
  schedule: Record<string, string> | null;
  /** `appearance` (the light or dark frame) or `time` (frames follow the sun). */
  dynamic: string;
};

/** A picture the background can show; `dynamic`: a macOS dynamic wallpaper (frames by sun or clock). */
export type PictureChoice = {
  id: string;
  title: string;
  collection?: string;
  video?: boolean;
  downloaded?: boolean;
  dynamic?: boolean;
};

/** One write: a value, or null to reset the key (unset). */
export type WallpaperWrite = readonly [key: string, value: unknown];

/** Whether `id` is one picture that stays (not a mode or a shuffle). */
export function isFixed(id: string): boolean {
  return (
    id !== FOLLOW_APPEARANCE && id !== FOLLOW_SCHEDULE && id !== SHUFFLE_PAINTINGS && !id.startsWith(FOLDER_PREFIX)
  );
}

/** A macOS dynamic wallpaper: the host marks it (`dynamic`); without the mark, a system `.madesktop`
 * or `.heic` reads as one (the engine falls back to its light and dark frames when it is not). */
export function isDynamicPicture(id: string, choices: readonly PictureChoice[]): boolean {
  if (!id.startsWith("system:")) return false;
  const choice = choices.find((item) => item.id === id);
  if (choice?.dynamic !== undefined) return choice.dynamic;
  return /\.(madesktop|heic)$/i.test(id);
}

/** The mode the values mean. A dynamic macOS picture following its own light and dark frames is
 * Off: one picture, as macOS shows it. */
export function modeOf(values: WallpaperValues, choices: readonly PictureChoice[]): WallpaperMode {
  const { background } = values;
  if (background === FOLLOW_APPEARANCE) return "appearance";
  if (background === FOLLOW_SCHEDULE) return "schedule";
  if (background === SHUFFLE_PAINTINGS || background.startsWith(FOLDER_PREFIX)) return "rotate";
  if (values.dynamic === "time" && isDynamicPicture(background, choices)) return "sun";
  return "off";
}

/** The dynamic pictures Sun can use, downloaded ones first. */
export function dynamicChoices(choices: readonly PictureChoice[]): PictureChoice[] {
  const dynamic = choices.filter((choice) => isDynamicPicture(choice.id, choices) && !choice.video);
  return [...dynamic.filter((choice) => choice.downloaded !== false), ...dynamic.filter((c) => c.downloaded === false)];
}

/** The one picture Off shows: the one on screen when the values hold one, else the light picture,
 * the first scheduled one, the last picture the page saw, or none. */
export function fixedPicture(values: WallpaperValues, lastFixed: string | null): string {
  if (isFixed(values.background)) return values.background;
  if (values.background === FOLLOW_APPEARANCE) return values.light ?? values.dark ?? lastFixed ?? "none";
  if (values.background === FOLLOW_SCHEDULE) {
    const first = values.schedule ? Object.values(values.schedule)[0] : undefined;
    return lastFixed ?? first ?? "none";
  }
  return lastFixed ?? "none";
}

/**
 * The writes that turn the values into `mode`, keeping what the person sees where it can: Light &
 * Dark starts with the current picture on the light side, Time of Day with it at sunrise and
 * sunset, Rotate shuffles the paintings, Sun uses the current dynamic picture (or the first one).
 * Off puts one fixed picture back and the dynamic picture on its light and dark frames.
 */
export function writesFor(
  mode: WallpaperMode,
  values: WallpaperValues,
  context: { choices: readonly PictureChoice[]; lastFixed: string | null },
): WallpaperWrite[] {
  const fixed = fixedPicture(values, context.lastFixed);
  // A mode's seed must be a picture: from no background, Light & Dark and Time of Day start on the desktop's.
  const seed = fixed === "none" ? "desktop" : fixed;
  const dynamicOff: WallpaperWrite[] = values.dynamic === "time" ? [[DYNAMIC_KEY, null]] : [];
  switch (mode) {
    case "off":
      return [...(values.background === fixed ? [] : [[BACKGROUND_KEY, fixed] as const]), ...dynamicOff];
    case "appearance":
      return [
        ...(values.light === null && values.dark === null ? [[LIGHT_KEY, seed] as const] : []),
        [BACKGROUND_KEY, FOLLOW_APPEARANCE],
        ...dynamicOff,
      ];
    case "schedule":
      return [
        ...(values.schedule && Object.keys(values.schedule).length > 0
          ? []
          : [[SCHEDULE_KEY, { sunrise: seed, sunset: seed }] as const]),
        [BACKGROUND_KEY, FOLLOW_SCHEDULE],
        ...dynamicOff,
      ];
    case "sun": {
      const picture = isDynamicPicture(values.background, context.choices)
        ? values.background
        : dynamicChoices(context.choices)[0]?.id;
      if (!picture) return [];
      return [...(picture === values.background ? [] : [[BACKGROUND_KEY, picture] as const]), [DYNAMIC_KEY, "time"]];
    }
    case "rotate":
      return [[BACKGROUND_KEY, SHUFFLE_PAINTINGS], ...dynamicOff];
  }
}

// When a scheduled picture starts: `HH:MM` (24 h, local) or a sun event with an offset
// (`sunset-30m`, `sunrise+1h`, `dusk+90m`).
export const SUN_EVENTS = ["dawn", "sunrise", "noon", "sunset", "dusk"] as const;
export type SunEvent = (typeof SUN_EVENTS)[number];
export type When = { kind: "time"; minutes: number } | { kind: "sun"; event: SunEvent; offset: number };

/** The offsets a sun event's row offers, in minutes. */
export const OFFSETS: readonly number[] = [-120, -90, -60, -45, -30, -15, 0, 15, 30, 45, 60, 90, 120];

const TIME = /^([01]\d|2[0-3]):([0-5]\d)$/;
const SUN = /^(dawn|sunrise|noon|sunset|dusk)(?:([+-])(\d+)(m|h))?$/;

export function parseWhen(key: string): When | null {
  const time = TIME.exec(key);
  if (time) return { kind: "time", minutes: Number(time[1]) * 60 + Number(time[2]) };
  const sun = SUN.exec(key);
  if (!sun) return null;
  const amount = sun[3] === undefined ? 0 : Number(sun[3]) * (sun[4] === "h" ? 60 : 1);
  return { kind: "sun", event: sun[1] as SunEvent, offset: sun[2] === "-" ? -amount : amount };
}

export function formatWhen(when: When): string {
  if (when.kind === "time") {
    const minutes = ((when.minutes % 1440) + 1440) % 1440;
    return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
  }
  if (when.offset === 0) return when.event;
  const sign = when.offset < 0 ? "-" : "+";
  const amount = Math.abs(when.offset);
  return `${when.event}${sign}${amount % 60 === 0 ? `${amount / 60}h` : `${amount}m`}`;
}

/** A typical day's sun times (minutes after midnight), only to place rows on the timeline strip;
 * the app computes the real ones for the location. */
const TYPICAL: Record<SunEvent, number> = { dawn: 360, sunrise: 390, noon: 720, sunset: 1110, dusk: 1140 };

/** Where in a typical day `when` falls, 0...1439. */
export function typicalMinutes(when: When): number {
  const minutes = when.kind === "time" ? when.minutes : TYPICAL[when.event] + when.offset;
  return ((minutes % 1440) + 1440) % 1440;
}

/** A key for a new row: the first of noon, sunrise, sunset, dusk, then whole hours, not yet used. */
export function nextWhen(schedule: Record<string, string>): string {
  const used = new Set(Object.keys(schedule));
  for (const candidate of ["sunrise", "sunset", "noon", "dusk", "dawn"]) if (!used.has(candidate)) return candidate;
  for (let hour = 0; hour < 24; hour += 1) {
    const key = formatWhen({ kind: "time", minutes: hour * 60 });
    if (!used.has(key)) return key;
  }
  return "00:30";
}

/** The schedule with the row at `from` moved to `to` (its place kept), or null when `to` is taken. */
export function renameWhen(schedule: Record<string, string>, from: string, to: string): Record<string, string> | null {
  if (from === to) return schedule;
  if (to in schedule) return null;
  return Object.fromEntries(Object.entries(schedule).map(([key, value]) => [key === from ? to : key, value]));
}

/** The schedule with `key` set to `picture` (a new key goes last). */
export function withEntry(schedule: Record<string, string>, key: string, picture: string): Record<string, string> {
  const next = { ...schedule };
  next[key] = picture;
  return next;
}
