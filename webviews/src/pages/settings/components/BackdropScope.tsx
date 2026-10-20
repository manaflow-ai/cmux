// The background picker's scope (cx-t2x.5): Change Background… on a workspace opens the picker for
// that workspace, which can keep its own background over appearance.background.
import { useEffect, useRef, useState } from "react";
import { useSettingsSelector, useStore } from "../context";
import type { WorkspaceBackground } from "../ops";
import { t } from "../strings";
import { opacityFloorOnGrid } from "./opacityFloor";

/** The tile that clears a workspace's own background, so it follows All Workspaces again. */
export const FOLLOW_ID = "follow";

/** The workspace `id`'s own background, read once per workspace; null without a workspace or when
 * the host has none. The setter records a saved value; `read` is false until the host answered. */
export function useWorkspaceBackground(id: string | null) {
  const store = useStore();
  const [background, setBackground] = useState<WorkspaceBackground | null>(null);
  const [read, setRead] = useState(id === null);
  useEffect(() => {
    setBackground(null);
    setRead(id === null);
    if (!id) return;
    let live = true;
    void store.workspaceBackground(id).then((reply) => {
      if (!live) return;
      setBackground(reply);
      setRead(true);
    });
    return () => {
      live = false;
    };
  }, [store, id]);
  return [background, setBackground, read] as const;
}

/** All Workspaces | This Workspace (<name>): which background the tiles choose. */
export function BackdropScopePicker({
  title,
  own,
  onChange,
}: {
  title: string;
  own: boolean;
  onChange: (own: boolean) => void;
}) {
  const choices = [
    { own: false, label: t("settingsWindow.backdropPicker.allWorkspaces") },
    { own: true, label: t("settingsWindow.backdropPicker.thisWorkspace", title) },
  ];
  return (
    <fieldset className="segmented backdrop-scope" aria-label={t("settingsWindow.backdropPicker.scope")}>
      {choices.map((choice) => (
        <label key={String(choice.own)} className="segment" data-checked={own === choice.own ? "" : undefined}>
          <input
            type="radio"
            name="backdrop-scope"
            aria-label={choice.label}
            checked={own === choice.own}
            onChange={() => onChange(choice.own)}
          />
          {choice.label}
        </label>
      ))}
    </fieldset>
  );
}

/** Where the slider rests while the workspace follows the work's own tint. */
const FOLLOW_OPACITY = 0.5;
/** How long keyboard steps pause before the tint is saved. */
const KEY_SAVE_MS = 400;
/** At 1 the glass hides the art (the host caps a workspace's tint the same way). */
const MAX_OPACITY = 0.95;
const STEP = 0.05;

/**
 * This Workspace's Opacity over art: the slider previews the tint while it moves (never written)
 * and saves it on release; Use the Work's Own clears it. The legibility floor keeps text readable
 * however low it goes.
 */
export function WorkspaceOpacity({
  background,
  onSaved,
}: {
  background: WorkspaceBackground;
  onSaved: (opacity: number | null) => void;
}) {
  const store = useStore();
  const [drag, setDrag] = useState<number | null>(null);
  const pending = useRef<number | null>(null);
  // A drag saves on release; keyboard steps save once they pause.
  const dragging = useRef(false);
  const keySave = useRef<ReturnType<typeof setTimeout> | null>(null);
  const stored = background.opacity ?? null;
  // Over a picture the window paints no tint below the legibility floor, the same floor as the
  // All Workspaces row (`derived_min`, the active window's): the slider starts there.
  const floor = useSettingsSelector((state) => state.host?.derived_min?.["appearance.backgroundOpacity"]);
  const min = opacityFloorOnGrid(floor, 0, STEP, MAX_OPACITY);
  const save = async (opacity: number | null) => {
    if (await store.setWorkspaceOpacity(background.workspace, opacity)) onSaved(opacity);
    // The slider keeps the chosen value until the save answered, so it never snaps back.
    setDrag(null);
    store.previewWorkspaceBackground(background.workspace, undefined);
  };
  const release = () => {
    if (keySave.current !== null) clearTimeout(keySave.current);
    keySave.current = null;
    const next = pending.current;
    if (next === null) return;
    pending.current = null;
    void save(next);
  };
  // Closing Settings mid-change saves nothing and drops the preview.
  const endOnLeave = useRef(() => {});
  endOnLeave.current = () => {
    if (keySave.current !== null) clearTimeout(keySave.current);
    if (pending.current !== null) store.previewWorkspaceBackground(background.workspace, undefined);
  };
  useEffect(() => () => endOnLeave.current(), []);
  return (
    <div className="rows">
      <div className="row" data-workspace-opacity="">
        <div className="row-main">
          <div className="row-label">
            <div className="row-title" id="workspace-opacity-label">
              {t("settingsWindow.backdropPicker.workspaceOpacity")}
            </div>
            <div className="row-help">
              {stored === null && drag === null
                ? t("settingsWindow.backdropPicker.workspaceOpacityFollows")
                : t("settingsWindow.backdropPicker.workspaceOpacityHelp")}
            </div>
            {min > 0 && (
              <div className="row-help">
                {t("settingsWindow.backdropPicker.opacityFloor", `${Math.round(min * 100)}%`)}
              </div>
            )}
          </div>
          <div className="row-control">
            <span className="number-editor">
              <input
                type="range"
                className="slider"
                min={min}
                max={MAX_OPACITY}
                step={STEP}
                value={Math.max(min, drag ?? stored ?? FOLLOW_OPACITY)}
                disabled={min >= MAX_OPACITY}
                aria-labelledby="workspace-opacity-label"
                onChange={(event) => {
                  const next = Math.max(min, Number(event.currentTarget.value));
                  pending.current = next;
                  setDrag(next);
                  store.previewWorkspaceOpacity(background.workspace, next);
                  if (dragging.current) return;
                  if (keySave.current !== null) clearTimeout(keySave.current);
                  keySave.current = setTimeout(release, KEY_SAVE_MS);
                }}
                onPointerDown={() => {
                  dragging.current = true;
                }}
                onPointerUp={() => {
                  dragging.current = false;
                  release();
                }}
                onBlur={() => {
                  dragging.current = false;
                  release();
                }}
              />
              {stored !== null && (
                <button type="button" className="link-button" onClick={() => void save(null)}>
                  {t("settingsWindow.backdropPicker.workspaceOpacityReset")}
                </button>
              )}
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}
