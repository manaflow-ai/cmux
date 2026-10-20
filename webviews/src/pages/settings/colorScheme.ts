import { useSyncExternalStore } from "react";

const darkQuery = "(prefers-color-scheme: dark)";
function subscribeScheme(onChange: () => void): () => void {
  const query = window.matchMedia?.(darkQuery);
  query?.addEventListener("change", onChange);
  return () => query?.removeEventListener("change", onChange);
}
const readScheme = (): "dark" | "light" => (window.matchMedia?.(darkQuery).matches ? "dark" : "light");

/** The system appearance the page is shown in (the app's, through WebKit), live: the side of a
 * light/dark theme pair in effect. */
export function useColorScheme(): "dark" | "light" {
  return useSyncExternalStore(subscribeScheme, readScheme, () => "dark");
}
