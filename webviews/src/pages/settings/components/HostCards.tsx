// The Swift window's remaining cards, drawn by the page (R82 commit 4): the background picker
// (Appearance, where Change Background… lands), the terminal facts (Terminal) and the settings
// file with its problems (Advanced). Data comes from the host lists; writes run host ops or
// catalog actions, the palette's paths.
import { useEffect, useRef, useState } from "react";
import { useSettingsState, useStore } from "../context";
import { settingsFileName } from "../format";
import { rowsByKey } from "../schema";
import { Icon } from "../icons";
import { locale, t } from "../strings";
import { ActionRow } from "./ActionRow";
import { ArtBrowser } from "./ArtBrowser";
import { BackdropLink, formatBytes } from "./BackdropLink";
import { BackdropScopePicker, FOLLOW_ID, useWorkspaceBackground, WindowGlass, WorkspaceOpacity } from "./BackdropScope";
import { SettingRow } from "./SettingRow";

export const BACKGROUND_KEY = "appearance.background";
export const BACKGROUND_OPACITY_KEY = "appearance.backgroundOpacity";
/** Shuffle Daily (cx-t2x.5): one work of the art set a day. */
const DAILY_ID = "daily";
/** The person's own images (BackdropUserImages.collection): removable, and shown in Finder. */
const YOURS = "yours";
/** The rows the picker draws, left out of their group while it shows. */
export const BACKDROP_ROWS: ReadonlySet<string> = new Set([BACKGROUND_KEY, BACKGROUND_OPACITY_KEY]);
/** How long the pointer rests on a tile before the window shows it: sweeping across the grid
 * previews nothing, so it fetches no full-size art. */
const PREVIEW_DWELL_MS = 150;

/** A tile's thumbnail; when the app answers none (a picture that is gone), an empty framed box
 * in place of the webview's broken-image mark. */
function BackdropThumb({ src }: { src: string }) {
  const [failed, setFailed] = useState<string | null>(null);
  if (failed === src) return <span className="backdrop-thumb backdrop-none" data-thumb-missing="" />;
  return <img className="backdrop-thumb" alt="" src={src} onError={() => setFailed(src)} />;
}

/** Change Background… (`?focus=appearance.background`) lands on the saved tile. Focusing it previews
 * the saved background, so nothing changes. */
function revealTile(tile: HTMLElement | null): void {
  tile?.scrollIntoView?.({ block: "center" });
  tile?.focus();
}

/** Whether the picker draws (the host lists the art); its rows show in their group otherwise. */
export function useBackdropsShown(): boolean {
  return (useSettingsState().host?.backdrops ?? []).length > 0;
}

/**
 * Change Background… (cx-t2x.4): the art picker. Resting on a tile, or focusing it, shows that
 * background in every window without writing it; a click keeps it; leaving restores the saved one.
 * Below the art, the Opacity slider previews the glass over it the same way. Plain glass ("None")
 * stays the default. Opened for a workspace, This Workspace makes the tiles choose that
 * workspace's own background (cx-t2x.5), shown while it is shown.
 */
export function Backdrops({ focus = null, workspace = null }: { focus?: string | null; workspace?: string | null }) {
  const store = useStore();
  const state = useSettingsState();
  const { host, rows } = state;
  const [browsing, setBrowsing] = useState(false);
  const [linking, setLinking] = useState(false);
  const [usage, setUsage] = useState<number | null>(null);
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
  if (backdrops.length === 0) return null;
  const background = rows.get(BACKGROUND_KEY);
  const current = own
    ? (own.value ?? FOLLOW_ID)
    : (((background?.value ?? background?.default) as string | undefined) ?? "none");
  const opacity = rowsByKey.get(BACKGROUND_OPACITY_KEY);
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
        /* tooltip-allow: what a click on a cloud tile does, or the credit the one-line tile drops */ title={
          pending ? t("settingsWindow.backdropPicker.downloadInSystemSettings") : credit
        }
        ref={focus === BACKGROUND_KEY && current === id && state.readable && workspaceRead ? revealTile : undefined}
        onClick={() => void (pending ? store.openWallpaperSettings() : choose(id))}
        onPointerEnter={pending ? undefined : () => preview(id, PREVIEW_DWELL_MS)}
        onPointerLeave={pending ? undefined : endPreview}
        onFocus={(event) => !pending && event.currentTarget.matches(":focus-visible") && preview(id, 0)}
        onBlur={pending ? undefined : endPreview}
      >
        {id === "none" || id === FOLLOW_ID ? (
          <span className="backdrop-thumb backdrop-none" />
        ) : id === DAILY_ID ? (
          <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
            ↻
          </span>
        ) : (
          <span className="backdrop-frame">
            {/* Encoded twice: the app decodes the URL path before splitting it on "/", then decodes
              the one segment, so a system: or file: id with slashes stays one segment. */}
            <BackdropThumb src={`backdrop/${encodeURIComponent(encodeURIComponent(id))}`} />
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
  // title, then the person's own images ("Your images"), the desktop picture in an untitled
  // group, and every macOS wallpaper ("Apple Wallpapers").
  const groups: Array<{ key: string; title: string | null; choices: typeof backdrops }> = [];
  for (const choice of backdrops) {
    const key = choice.collection ?? "";
    const last = groups[groups.length - 1];
    if (last && last.key === key) last.choices.push(choice);
    else groups.push({ key, title: choice.collection_title ?? null, choices: [choice] });
  }
  return (
    <section className="group" data-card="backdrop">
      <h3 className="group-title">{t("settingsWindow.backdropPicker.title")}</h3>
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
      {own && (
        <WorkspaceOpacity background={own} onSaved={(saved) => setWorkspaceBackground({ ...own, opacity: saved })} />
      )}
      {!own && (
        <div className="rows">
          {opacity && <SettingRow row={opacity} focused={focus === BACKGROUND_OPACITY_KEY} />}
          <WindowGlass />
        </div>
      )}
      <div className="backdrop-grid">
        {own &&
          tile(
            FOLLOW_ID,
            t("settingsWindow.backdropPicker.followAll"),
            t("settingsWindow.backdropPicker.followAllHelp"),
          )}
        {tile("none", t("settingsWindow.backdropPicker.none"), t("settingsWindow.backdropPicker.none"))}
        {tile(
          DAILY_ID,
          t("settingsWindow.backdropPicker.shuffleDaily"),
          t("settingsWindow.backdropPicker.shuffleDailyHelp"),
        )}
        {/* Both set the background for All Workspaces; this workspace picks its own images below. */}
        {!own && (
          <>
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
      {browsing && !own && <ArtBrowser onClose={() => setBrowsing(false)} />}
      {linking && !own && <BackdropLink onClose={() => setLinking(false)} />}
      {groups.map((group) => (
        <div key={group.key || "other"} className="backdrop-group" data-collection={group.key || undefined}>
          {group.title && <h4 className="row-help backdrop-group-title">{group.title}</h4>}
          {group.key === YOURS && (
            <div className="backdrop-own-bar">
              {usage !== null && (
                <span className="row-help">
                  {t("settingsWindow.backdropPicker.usage", formatBytes(usage, locale()))}
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
                  {tile(choice.id, choice.title, choice.attribution, choice)}
                  {/* The background in use stays: removing it would leave the window blank. */}
                  <button
                    type="button"
                    className="icon-button backdrop-remove"
                    aria-label={t("settingsWindow.backdropPicker.remove", choice.title)}
                    disabled={current === choice.id}
                    onClick={() => void store.removeBackdropImage(choice.id).then((bytes) => setUsage(bytes))}
                  >
                    ×
                  </button>
                </div>
              ) : (
                tile(choice.id, choice.title, choice.attribution, choice)
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
