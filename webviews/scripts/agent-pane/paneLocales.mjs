// The agent pane's strings in a Vite build of its dev entry (vite.config.acpmux-pane.mjs, which the
// chat-open, chat-switch and other pane benches build): locales/<code>.js beside index.html and the
// <head> loader that runs English plus the page's language before the module, as
// scripts/cmux-next/build-agent-pane-web.sh ships them. dev.tsx then finds __cmuxPaneStrings set and
// never imports its whole table (all 21 locales, 3.5 MiB of script the app never loads). The dev
// server (serve) keeps the whole table, so every language switches live.
import fs from "node:fs";
import { splitStrings } from "../pages/split-strings.mjs";

export function paneLocales(stringsJson) {
  let split;
  const load = () =>
    (split ??= splitStrings(JSON.parse(fs.readFileSync(stringsJson, "utf8")), {
      global: "__cmuxPaneStrings",
      loaderFile: true,
    }));
  return {
    name: "cmux-agent-pane-locales",
    apply: "build",
    generateBundle() {
      for (const [name, source] of Object.entries(load().files))
        this.emitFile({ type: "asset", fileName: `locales/${name}`, source });
    },
    transformIndexHtml: {
      order: "post",
      handler: (html) => html.replace(/<script type="module"/, `${load().tags}\n    <script type="module"`),
    },
  };
}
