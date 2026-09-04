import { darkThemeColor, lightThemeColor } from "../[locale]/theme-colors";

/**
 * Applies the visitor's saved theme before the auth card paints.
 *
 * next-themes runs under `[locale]`, and `/handler` is outside it, so these
 * pages would otherwise always render light while the site default is dark.
 * Mounting the provider here would put React back on the sign-in path for one
 * class name, so this reads the same `theme` key next-themes writes and sets
 * the same class. Keep the key, the default, and the values in step with
 * `app/[locale]/providers.tsx`.
 *
 * With JavaScript off the page stays light. Every auth flow is server-driven,
 * so that costs appearance and nothing else.
 */
export function AuthThemeScript() {
  const source = `(function(){try{` +
    `var t=localStorage.getItem("theme")||"dark";` +
    `if(t==="system"){t=window.matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light"}` +
    `var e=document.documentElement;` +
    `e.classList.remove("light","dark");e.classList.add(t);` +
    `e.style.colorScheme=t;` +
    `var c=t==="dark"?${JSON.stringify(darkThemeColor)}:${JSON.stringify(lightThemeColor)};` +
    `document.querySelectorAll('meta[name="theme-color"]').forEach(function(m){m.setAttribute("content",c)});` +
    `}catch(_){}})()`;
  return (
    <script suppressHydrationWarning dangerouslySetInnerHTML={{ __html: source }} />
  );
}
