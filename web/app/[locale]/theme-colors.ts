export const darkThemeColor = "#0a0a0a";
export const lightThemeColor = "#fafafa";

/**
 * Applies the stored theme before first paint. Every page tree that renders
 * site chrome mounts it through `ThemeBootstrapScript`.
 */
export const siteThemeBootstrapScript = `(function(){try{var t=localStorage.getItem("theme");var light=t==="light"||(t==="system"&&window.matchMedia("(prefers-color-scheme:light)").matches);if(!light)document.documentElement.classList.add("dark");document.querySelectorAll('meta[name="theme-color"]').forEach(function(m){m.content=light?"${lightThemeColor}":"${darkThemeColor}"})}catch(e){}})()`;
