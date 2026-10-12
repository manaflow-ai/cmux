// The background picker's scope (cx-t2x.5): Change Background… on a workspace opens the picker for
// that workspace, which can keep its own background over appearance.background.
import { useEffect, useRef, useState } from "react";
import { useStore } from "../context";
import type { WorkspaceBackground } from "../ops";
import { t } from "../strings";

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
/** At 1 the glass hides the art (the host caps a workspace's tint the same way). */
const MAX_OPACITY = 0.95;

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
  // A drag saves on release; a keyboard step saves at once.
  const dragging = useRef(false);
  const stored = background.opacity ?? null;
  const save = async (opacity: number | null) => {
    if (await store.setWorkspaceOpacity(background.workspace, opacity)) onSaved(opacity);
    store.previewWorkspaceBackground(background.workspace, undefined);
  };
  const release = () => {
    const next = pending.current;
    if (next === null) return;
    pending.current = null;
    setDrag(null);
    void save(next);
  };
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
          </div>
          <div className="row-control">
            <span className="number-editor">
              <input
                type="range"
                className="slider"
                min={0}
                max={MAX_OPACITY}
                step={0.05}
                value={drag ?? stored ?? FOLLOW_OPACITY}
                aria-labelledby="workspace-opacity-label"
                onChange={(event) => {
                  const next = Number(event.currentTarget.value);
                  pending.current = next;
                  setDrag(next);
                  store.previewWorkspaceOpacity(background.workspace, next);
                  if (!dragging.current) release();
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
