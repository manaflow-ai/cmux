import { useEffect, useRef, useState } from "react";
import {
  type SavedEnvironment,
  type SavedEnvironmentDraft,
  type SavedEnvironmentHost,
  withSavedEnvironment,
} from "../environments";

/// The New Tab page's saved environments (preview): the host's list, read once the page has a
/// host for them; the one the environment picker picked; and the one the inline panel edits (`null`:
/// a new one; `undefined`: no panel). Saves and removals go to the host; the list follows at once
/// and the host's answer replaces it.
export function useSavedEnvironments(host: SavedEnvironmentHost | undefined) {
  const on = host !== undefined;
  const [list, setList] = useState<SavedEnvironment[]>([]);
  const [pickedId, setPickedId] = useState<string>();
  const [editing, setEditing] = useState<SavedEnvironment | null | undefined>(undefined);
  // The App hands new actions on each render: the list is read when a host arrives, not then.
  const latest = useRef(host);
  latest.current = host;
  useEffect(() => {
    if (!on) return;
    let live = true;
    void latest.current?.list().then(
      (environments) => {
        // A save that landed first stays: the host's list may predate it.
        if (live)
          setList((current) => [
            ...current.filter((kept) => !environments.some((environment) => environment.id === kept.id)),
            ...environments,
          ]);
      },
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [on]);
  const picked = on ? list.find((environment) => environment.id === pickedId) : undefined;
  return {
    on,
    list,
    picked,
    editing,
    pick: setPickedId,
    edit: setEditing,
    /// Saves through the host, then picks what it kept and closes the panel; rejects with the
    /// host's reason (the panel shows it).
    async save(draft: SavedEnvironmentDraft) {
      const host = latest.current;
      if (!host) throw new Error("environment.save");
      const environment = await host.save(draft);
      setList((current) => withSavedEnvironment(current, environment));
      setPickedId(environment.id);
      setEditing(undefined);
    },
    remove(environment: SavedEnvironment) {
      setList((current) => current.filter((other) => other.id !== environment.id));
      setPickedId((current) => (current === environment.id ? undefined : current));
      setEditing((current) => (current?.id === environment.id ? undefined : current));
      const host = latest.current;
      // A removal the host refused comes back with its list.
      void host
        ?.remove(environment.id)
        .catch(() => host.list().then(setList))
        .catch(() => undefined);
    },
  };
}
