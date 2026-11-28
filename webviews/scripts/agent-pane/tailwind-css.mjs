// Prints the agent pane's Tailwind stylesheet: acpmux/tailwind.css compiled over the classes the
// pane's sources use (tailwindCompile.mjs). build-agent-pane-web.sh concatenates raw CSS (no Vite),
// so this is the step that turns utility classes into rules; the gallery gets the same file through
// Vite's plugin.
//
//   bun scripts/agent-pane/tailwind-css.mjs src/agent-session/acpmux/tailwind.css > tailwind.out.css
import path from "node:path";
import { compileTailwind } from "./tailwindCompile.mjs";

process.stdout.write(
  `${await compileTailwind(path.resolve(process.argv[2] ?? "src/agent-session/acpmux/tailwind.css"))}\n`,
);
