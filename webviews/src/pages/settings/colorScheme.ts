import { useSyncExternalStore } from "react";
import { useSettingsState } from "./context";

const darkQuery = "(prefers-color-scheme: dark)";
function subscribeScheme(onChange: () => void): () => void {
  const query = window.matchMedia?.(darkQuery);
  query?.addEventListener("change", onChange);
  return () => query?.removeEventListener("change", onChange);
}
const readScheme = (): "dark" | "light" => (window.matchMedia?.(darkQuery).matches ? "dark" : "light");

/** The Mac's light or dark, live: the side of a light/dark theme pair in effect. The host sends it
 * (`theme.system_scheme`); the page's own prefers-color-scheme is its window's, which a light or
 * dark App Theme sets, so it is only the fallback before the host answers. */
export function useColorScheme(): "dark" | "light" {
  const page = useSyncExternalStore(subscribeScheme, readScheme, (): "dark" | "light" => "dark");
  return useSettingsState().host?.theme?.system_scheme ?? page;
}
