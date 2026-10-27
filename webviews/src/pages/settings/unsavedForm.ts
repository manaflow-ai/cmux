import { useEffect } from "react";
import { useStore } from "./context";

/**
 * Reports to the host while the form `form` holds typed values it has not saved (`unsaved`), and
 * that it no longer does when it saves, empties or unmounts. The host keeps a hidden Settings tab
 * whose page has such a form instead of letting the page go (SettingsWindowService.keepReasons).
 */
export function useUnsavedForm(form: string, unsaved: boolean): void {
  const store = useStore();
  useEffect(() => {
    if (!unsaved) return;
    store.setUnsavedForm(form, true);
    return () => store.setUnsavedForm(form, false);
  }, [store, form, unsaved]);
}
