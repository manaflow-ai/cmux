// The Swift window's remaining cards, drawn by the page (R82 commit 4): the background picker
// (Appearance, where Change Background… lands), the terminal facts (Terminal) and the settings
// file with its problems (Advanced). Data comes from the host lists; writes run host ops or
// catalog actions, the palette's paths.
import { useEffect, useId, useRef, useState } from "react";
import { useSettingsState, useStore } from "../context";
import { settingsFileName } from "../format";
import { rowsByKey } from "../schema";
import { Icon } from "../icons";
import { locale, t } from "../strings";
import { ActionRow } from "./ActionRow";
import { ArtBrowser } from "./ArtBrowser";
import { BackdropLink, formatBytes } from "./BackdropLink";
import { BackdropScopePicker, FOLLOW_ID, useWorkspaceBackground, WorkspaceOpacity } from "./BackdropScope";
import { SettingRow } from "./SettingRow";

export const BACKGROUND_KEY = "appearance.background";
export const BACKGROUND_OPACITY_KEY = "appearance.backgroundOpacity";
/** Shuffle Paintings (cx-t2x.5): the art set, turning as often as appearance.backgroundRotation says. */
const DAILY_ID = "daily";
/** The person's desktop picture (BackdropSelection.desktopID), first in the picker. */
const DESKTOP_ID = "desktop";
/** The person's own images (BackdropUserImages.collection): removable, and shown in Finder. */
const YOURS = "yours";
/** The rows the picker draws, left out of their group while it shows. */
/** `appearance.backgroundBlur`: the window's Material, drawn in the card beside Opacity. */
export const MATERIAL_KEY = "appearance.backgroundBlur";
/** `appearance.backgroundRotation`: how often a shuffle turns, shown in the card while one is chosen. */
export const ROTATION_KEY = "appearance.backgroundRotation";
export const BACKDROP_ROWS: ReadonlySet<string> = new Set([
  BACKGROUND_KEY,
  BACKGROUND_OPACITY_KEY,
  MATERIAL_KEY,
  ROTATION_KEY,
]);
/** `folder:<absolute path>`: the pictures in that folder, shuffled. */
const FOLDER_PREFIX = "folder:";
const folderName = (id: string) => id.slice(FOLDER_PREFIX.length).split("/").filter(Boolean).at(-1) ?? id;
/** How long the pointer or keyboard focus rests on a tile before the window shows it: sweeping
 * or tabbing across the grid previews nothing, so it fetches no full-size art. */
const PREVIEW_DWELL_MS = 150;

/** A tile's thumbnail; when the app answers none (a picture that is gone), an empty framed box
 * in place of the webview's broken-image mark. */
function BackdropThumb({ src }: { src: string }) {
  const [failed, setFailed] = useState<string | null>(null);
  if (failed === src) return <span className="backdrop-thumb backdrop-none" data-thumb-missing="" />;
  return <img className="backdrop-thumb" alt="" src={src} onError={() => setFailed(src)} />;
}

/** Change Background… (`?focus=appearance.background`) lands on the saved tile. Focus resting on it
 * previews the saved background after the dwell, so nothing changes. */
function revealTile(tile: HTMLElement | null): void {
  tile?.scrollIntoView?.({ block: "center" });
  tile?.focus();
}

/** Whether the picker draws (the host lists the art); its rows show in their group otherwise. */
export function useBackdropsShown(): boolean {
  return (useSettingsState().host?.backdrops ?? []).length > 0;
}

/**
 * Change Background… (cx-t2x.4): the art picker. Resting on a tile with the pointer or focus shows that
 * background in every window without writing it; a click keeps it; leaving restores the saved one.
 * Below the art, the Opacity slider previews the glass over it the same way. Plain glass ("None")
 * stays the default. Opened for a workspace, This Workspace makes the tiles choose that
 * workspace's own background (cx-t2x.5), shown while it is shown.
 */
export function Backdrops({ focus = null, workspace = null }: { focus?: string | null; workspace?: string | null }) {
  const store = useStore();
  // What a tile's badges say to VoiceOver (the ▶ of a video, the cloud of a pending download).
  // It stands in for the credit tooltip as VoiceOver's description; the credit stays the pointer's
  // tooltip, and a video's title already names the wallpaper.
  const describe = useId();
  const state = useSettingsState();
  const { host, rows } = state;
  const [browsing, setBrowsing] = useState(false);
  const [linking, setLinking] = useState(false);
  // What the person's own images take, and their folder (Shuffle Your Images is `folder:` it).
  const [usage, setUsage] = useState<{ bytes: number; folder: string | null } | null>(null);
  // The macOS screen saver's aerial (Use My Screen Saver); null when it is not one.
  const [screenSaver, setScreenSaver] = useState<{ id: string; pending: boolean } | null>(null);
  const dwell = useRef<ReturnType<typeof setTimeout> | null>(null);
  // How to end the running preview: the app's, or a workspace's.
  const previewing = useRef<(() => void) | null>(null);
  const [workspaceBackground, setWorkspaceBackground, workspaceRead] = useWorkspaceBackground(workspace);
  // All Workspaces until This Workspace is picked: Change Background… keeps choosing for every window.
  const [ownScope, setOwnScope] = useState(false);
  const own = ownScope ? workspaceBackground : null;
  const backdrops = host?.backdrops ?? [];
  const cancelDwell = () => {
    if (dwell.current !== null) clearTimeout(dwell.current);
    dwell.current = null;
  };
  const preview = (id: string, delay: number) => {
    cancelDwell();
    dwell.current = setTimeout(() => {
      dwell.current = null;
      previewing.current?.();
      if (own) {
        const target = own.workspace;
        previewing.current = () => store.previewWorkspaceBackground(target, undefined);
        store.previewWorkspaceBackground(target, id === FOLLOW_ID ? null : id);
      } else {
        previewing.current = () => store.previewEnd(BACKGROUND_KEY);
        store.preview(BACKGROUND_KEY, id);
      }
    }, delay);
  };
  const endPreview = () => {
    cancelDwell();
    const end = previewing.current;
    previewing.current = null;
    end?.();
  };
  // Closing Settings or leaving Appearance mid-preview restores the saved background.
  const endOnLeave = useRef(endPreview);
  endOnLeave.current = endPreview;
  useEffect(() => () => endOnLeave.current(), []);
  // What the person's own images take, read again whenever their number changes.
  const ownCount = (host?.backdrops ?? []).filter((choice) => choice.collection === YOURS).length;
  useEffect(() => {
    if (ownCount === 0) return setUsage(null);
    let live = true;
    void store.backdropUsage().then((bytes) => live && setUsage(bytes));
    return () => {
      live = false;
    };
  }, [store, ownCount]);
  // Read again when the person is back from System Settings, where the screen saver is chosen.
  useEffect(() => {
    let live = true;
    const read = () => void store.screenSaverBackdrop().then((saver) => live && setScreenSaver(saver));
    read();
    window.addEventListener("focus", read);
    return () => {
      live = false;
      window.removeEventListener("focus", read);
    };
  }, [store]);
  if (backdrops.length === 0) return null;
  const background = rows.get(BACKGROUND_KEY);
  const appCurrent = ((background?.value ?? background?.default) as string | undefined) ?? "none";
  const current = own ? (own.value ?? FOLLOW_ID) : appCurrent;
  // A workspace's tint is over its picture: with its own No wallpaper there is nothing for Opacity
  // over Art to change. A workspace that follows may still show a picture the page does not see
  // (a window's own, `appearance.set scope=window`), so it keeps the slider.
  const ownPicture = own !== null && own.value !== "none";
  const opacity = rowsByKey.get(BACKGROUND_OPACITY_KEY);
  const material = rowsByKey.get(MATERIAL_KEY);
  const rotation = rowsByKey.get(ROTATION_KEY);
  // Shuffle Your Images: the folder the person's own images are in, once there are some.
  const yours = usage?.folder ? FOLDER_PREFIX + usage.folder : null;
  // A folder shuffled that is not Your Images: its own tile, chosen, by the folder's name.
  const otherFolder = !own && current.startsWith(FOLDER_PREFIX) && current !== yours ? current : null;
  const shuffles = current === DAILY_ID || current.startsWith(FOLDER_PREFIX);
  const choose = async (id: string) => {
    cancelDwell();
    if (own) {
      const value = id === FOLLOW_ID ? null : id;
      if (await store.setWorkspaceBackground(own.workspace, value)) {
        setWorkspaceBackground({ ...own, value });
        // Saving dropped the host's preview; nothing is left to end.
        previewing.current = null;
      }
    } else {
      await store.set(BACKGROUND_KEY, id);
    }
    endPreview();
  };
  // `attribution` null: the name alone (an Apple wallpaper). `video`: a moving wallpaper, marked
  // over its first frame. `pending`: a macOS wallpaper macOS has not downloaded, dimmed with a
  // cloud; a click opens the Wallpaper pane, which downloads it.
  const tile = (
    id: string,
    title: string,
    attribution: string | null,
    choice?: { video?: boolean; pending?: boolean },
  ) => {
    const pending = choice?.pending === true;
    // One title line under the thumbnail (macOS 15 tester, 2026-10-19: the wrapped credit lines under
    // each art tile overlapped and overwhelmed the grid); the full credit is the tile's tooltip.
    const credit =
      attribution === null || attribution === "" || attribution === title
        ? undefined
        : attribution.startsWith(title)
          ? attribution
          : `${title}\n${attribution}`;
    return (
      <button
        type="button"
        key={id}
        className={pending ? "backdrop-tile backdrop-pending" : "backdrop-tile"}
        aria-pressed={current === id}
        aria-label={title}
        aria-describedby={
          [choice?.video ? `${describe}-video` : null, pending ? `${describe}-pending` : null]
            .filter(Boolean)
            .join(" ") || undefined
        }
        /* tooltip-allow: what a click on a cloud tile does, or the credit the one-line tile drops */ title={
          pending ? t("settingsWindow.backdropPicker.downloadInSystemSettings") : credit
        }
        ref={focus === BACKGROUND_KEY && current === id && state.readable && workspaceRead ? revealTile : undefined}
        onClick={() => void (pending ? store.openWallpaperSettings() : choose(id))}
        onPointerEnter={pending ? undefined : () => preview(id, PREVIEW_DWELL_MS)}
        onPointerLeave={pending ? undefined : endPreview}
        onFocus={(event) => !pending && event.currentTarget.matches(":focus-visible") && preview(id, PREVIEW_DWELL_MS)}
        onBlur={pending ? undefined : endPreview}
      >
        {id === "none" || id === FOLLOW_ID ? (
          <span className="backdrop-thumb backdrop-none" />
        ) : id === DAILY_ID || id.startsWith(FOLDER_PREFIX) ? (
          <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
            ↻
          </span>
        ) : (
          <span className="backdrop-frame">
            {/* Encoded twice: the app decodes the URL path before splitting it on "/", then decodes
              the one segment, so a system: or file: id with slashes stays one segment. */}
            {/* An aerial macOS has not downloaded has no frame to show yet: an empty tile. */}
            {pending && choice?.video ? (
              <span className="backdrop-thumb backdrop-none" />
            ) : (
              <BackdropThumb src={`backdrop/${encodeURIComponent(encodeURIComponent(id))}`} />
            )}
            {pending && <Icon name="icloud.and.arrow.down" className="backdrop-download" />}
          </span>
        )}
        {choice?.video && (
          <span className="backdrop-badge" aria-hidden="true">
            ▶
          </span>
        )}
        <span className="backdrop-title">{title}</span>
      </button>
    );
  };
  // Art arrives grouped by collection (Dark Art, Museum Icons, Calm, Doré), each under its
  // title, then the person's own images ("Your images") and every macOS wallpaper ("Apple
  // Wallpapers"). The desktop picture is drawn first instead, in the top row.
  const groups: Array<{ key: string; title: string | null; choices: typeof backdrops }> = [];
  // The desktop picture leads the picker (Leo: "use my wallpaper stuff ... stick it wayyy up there").
  const desktop = backdrops.find((choice) => choice.id === DESKTOP_ID);
  const saverChoice = screenSaver ? backdrops.find((choice) => choice.id === screenSaver.id) : undefined;
  for (const choice of backdrops) {
    if (choice.id === DESKTOP_ID) continue;
    const key = choice.collection ?? "";
    const last = groups[groups.length - 1];
    if (last && last.key === key) last.choices.push(choice);
    else groups.push({ key, title: choice.collection_title ?? null, choices: [choice] });
  }
  return (
    <section className="group" data-card="backdrop">
      <h3 className="group-title">{t("settingsWindow.backdropPicker.title")}</h3>
      {/* Hidden: read only as a tile's description, never as text of their own in the card. */}
      <span id={`${describe}-video`} hidden>
        {t("settingsWindow.backdropPicker.video")}
      </span>
      <span id={`${describe}-pending`} hidden>
        {t("settingsWindow.backdropPicker.downloadInSystemSettings")}
      </span>
      {/* The happy path first: one background for every window, or one that turns on its own. */}
      <div className="backdrop-grid">
        {/* The person's own desktop picture and screen saver first: the quickest way to a background. */}
        {desktop && tile(desktop.id, desktop.title, desktop.attribution)}
        {screenSaver &&
          tile(screenSaver.id, t("settingsWindow.backdropPicker.screenSaver"), saverChoice?.title ?? null, {
            video: true,
            pending: screenSaver.pending,
          })}
        {own &&
          tile(
            FOLLOW_ID,
            t("settingsWindow.backdropPicker.followAll"),
            t("settingsWindow.backdropPicker.followAllHelp"),
          )}
        {tile("none", t("settingsWindow.backdropPicker.none"), t("settingsWindow.backdropPicker.none"))}
        {tile(
          DAILY_ID,
          t("settingsWindow.backdropPicker.shufflePaintings"),
          t("settingsWindow.backdropPicker.shufflePaintingsHelp"),
        )}
        {/* Folders shuffle for All Workspaces; a workspace picks its own images below. */}
        {!own &&
          yours &&
          tile(
            yours,
            t("settingsWindow.backdropPicker.shuffleYours"),
            t("settingsWindow.backdropPicker.shuffleYoursHelp"),
          )}
        {otherFolder &&
          tile(
            otherFolder,
            t("settingsWindow.backdropPicker.shufflingFolder", folderName(otherFolder)),
            otherFolder.slice(FOLDER_PREFIX.length),
          )}
        {/* These set the background for All Workspaces; this workspace picks its own images below. */}
        {!own && (
          <>
            <button type="button" className="backdrop-tile" onClick={() => void store.chooseBackdropFolder()}>
              <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
                ▦
              </span>
              <span className="backdrop-title">{t("settingsWindow.backdropPicker.shuffleFolder")}</span>
              <span className="row-help">{t("settingsWindow.backdropPicker.shuffleFolderHelp")}</span>
            </button>
            <button type="button" className="backdrop-tile" onClick={() => void store.chooseBackdropImage()}>
              <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
                +
              </span>
              <span className="backdrop-title">{t("settingsWindow.backdropPicker.chooseImage")}</span>
              <span className="row-help">{t("settingsWindow.backdropPicker.dropHint")}</span>
            </button>
            <button
              type="button"
              className="backdrop-tile"
              aria-expanded={browsing}
              onClick={() => setBrowsing((open) => !open)}
            >
              <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
                ⌕
              </span>
              <span className="backdrop-title">{t("settingsWindow.artBrowser.open")}</span>
              <span className="row-help">{t("settingsWindow.artBrowser.help")}</span>
            </button>
            <button
              type="button"
              className="backdrop-tile"
              aria-expanded={linking}
              onClick={() => setLinking((open) => !open)}
            >
              <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
                ↓
              </span>
              <span className="backdrop-title">{t("settingsWindow.backdropPicker.fromLink")}</span>
              <span className="row-help">{t("settingsWindow.backdropPicker.fromLinkHelp")}</span>
            </button>
          </>
        )}
      </div>
      {/* Secondary: Change Background… opens on All Workspaces; one workspace may keep its own. */}
      {workspaceBackground && (
        <BackdropScopePicker
          title={workspaceBackground.title}
          own={own !== null}
          onChange={(choice) => {
            endPreview();
            setOwnScope(choice);
          }}
        />
      )}
      {own && ownPicture && (
        <WorkspaceOpacity background={own} onSaved={(saved) => setWorkspaceBackground({ ...own, opacity: saved })} />
      )}
      <div className="rows">
        {/* How often the shuffle turns: the app's, so only for All Workspaces. Off without a shuffle,
          but still here, so search and a deep link find it. */}
        {!own && rotation && <SettingRow row={rotation} focused={focus === ROTATION_KEY} inactive={!shuffles} />}
        {!own && opacity && <SettingRow row={opacity} focused={focus === BACKGROUND_OPACITY_KEY} />}
        {/* The window's other control, on either scope: Frosted, Glass, Clear Glass (the desktop
          through the wallpaper) or None. It replaces the Window Glass switch, which set Clear Glass. */}
        {material && <SettingRow row={material} focused={focus === MATERIAL_KEY} />}
      </div>
      {browsing && !own && <ArtBrowser onClose={() => setBrowsing(false)} />}
      {linking && !own && <BackdropLink onClose={() => setLinking(false)} />}
      {groups.map((group) => (
        <div key={group.key || "other"} className="backdrop-group" data-collection={group.key || undefined}>
          {group.title && <h4 className="row-help backdrop-group-title">{group.title}</h4>}
          {group.key === YOURS && (
            <div className="backdrop-own-bar">
              {usage !== null && (
                <span className="row-help">
                  {t("settingsWindow.backdropPicker.usage", formatBytes(usage.bytes, locale()))}
                </span>
              )}
              <button type="button" className="button" onClick={() => store.revealBackdropImage()}>
                {t("settingsWindow.showInFinder")}
              </button>
            </div>
          )}
          <div className="backdrop-grid">
            {group.choices.map((choice) =>
              choice.collection === "apple" ? (
                tile(choice.id, choice.title, null, { pending: choice.downloaded === false })
              ) : choice.collection === YOURS ? (
                <div className="backdrop-own" key={choice.id}>
                  {tile(choice.id, choice.title, choice.attribution, {
                    video: choice.video,
                    pending: choice.downloaded === false,
                  })}
                  {/* The background in use stays: removing it would leave the window blank. */}
                  <button
                    type="button"
                    className="icon-button backdrop-remove"
                    aria-label={t("settingsWindow.backdropPicker.remove", choice.title)}
                    disabled={current === choice.id}
                    onClick={() =>
                      void store
                        .removeBackdropImage(choice.id)
                        .then((bytes) =>
                          setUsage((now) => (bytes === null ? null : { bytes, folder: now?.folder ?? null })),
                        )
                    }
                  >
                    ×
                  </button>
                </div>
              ) : (
                tile(choice.id, choice.title, choice.attribution, {
                  video: choice.video,
                  pending: choice.downloaded === false,
                })
              ),
            )}
          </div>
        </div>
      ))}
    </section>
  );
}

export function TerminalInfo() {
  const { host } = useSettingsState();
  if (!host?.terminal) return null;
  return (
    <section className="group" data-card="terminal">
      <div className="rows">
        <ActionRow title={t("settingsWindow.ghosttyConfig")} help="">
          <span className="row-help selectable">{host.terminal.ghostty_config}</span>
        </ActionRow>
        <ActionRow title={t("settingsWindow.shellIntegration")} help="">
          <span className="row-help selectable">
            {host.terminal.shell_integration ?? t("settingsWindow.shellIntegrationUnknown")}
          </span>
        </ActionRow>
      </div>
    </section>
  );
}

export function AdvancedInfo() {
  const store = useStore();
  const { host, problems } = useSettingsState();
  return (
    <>
      {host?.settings_file && (
        <section className="group" data-card="advanced">
          <div className="rows">
            <ActionRow title={t("settingsWindow.settingsFile")} help="">
              <span className="row-help selectable">{host.settings_file}</span>
              <button type="button" className="button" onClick={() => store.revealSettingsFile()}>
                {t("settingsWindow.showInFinder")}
              </button>
            </ActionRow>
          </div>
        </section>
      )}
      <section className="group" data-card="problems">
        <h3 className="group-title">{t("settingsWindow.problems", settingsFileName(host))}</h3>
        <div className="rows">
          {problems.length === 0 ? (
            <div className="row">
              <div className="empty">{t("settingsWindow.noProblems")}</div>
            </div>
          ) : (
            problems.map((problem, index) => (
              <div className="row selectable" key={`${problem.path}-${index}`} data-problem="">
                <div className="row-title">{problem.path || settingsFileName(host)}</div>
                <div className="row-help">{problem.message}</div>
              </div>
            ))
          )}
        </div>
      </section>
    </>
  );
}
