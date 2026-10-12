// The background picker's scope (cx-t2x.5): Change Background… on a workspace opens the picker for
// that workspace, which can keep its own background over appearance.background.
import { useEffect, useState } from "react";
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
