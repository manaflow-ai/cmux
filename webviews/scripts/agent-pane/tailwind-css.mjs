// Prints the agent pane's Tailwind stylesheet: acpmux/tailwind.css compiled over the classes the
// pane's sources use. build-agent-pane-web.sh concatenates raw CSS (no Vite), so this is the step
// that turns utility classes into rules; the gallery gets the same file through Vite's plugin.
//
//   bun scripts/agent-pane/tailwind-css.mjs src/agent-session/acpmux/tailwind.css > tailwind.out.css
import { readFileSync } from "node:fs";
import path from "node:path";
import { compile } from "@tailwindcss/node";
import { Scanner } from "@tailwindcss/oxide";

const entry = path.resolve(process.argv[2] ?? "src/agent-session/acpmux/tailwind.css");
const base = path.dirname(entry);
const compiler = await compile(readFileSync(entry, "utf8"), { base, onDependency: () => {} });
// The pane's sources: acpmux and the shared UI it renders (ui/).
const roots = [base, path.resolve(base, "../../ui")];
const scanner = new Scanner({
  sources: roots.map((root) => ({ base: root, pattern: "**/*.{ts,tsx}", negated: false })),
});
const css = compiler.build(scanner.scan());
if (!css.includes("@layer utilities")) {
  console.error("tailwind-css: the compiled stylesheet has no utilities layer; check acpmux/tailwind.css");
  process.exit(1);
}
process.stdout.write(`${css}\n`);
