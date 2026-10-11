// Compiles a Tailwind entry (`tailwind.css`: theme and utilities, no Preflight) over the classes
// its sources use, outside Vite: the app builds bundle with esbuild and concatenate raw CSS. The
// sources are the entry's own `@source` lines; an entry without any (`source(none)` and no
// `@source`) scans its own folder and the shared UI (src/ui), the agent pane's rule.
import { readFileSync } from "node:fs";
import path from "node:path";
import { compile } from "@tailwindcss/node";
import { Scanner } from "@tailwindcss/oxide";

export async function compileTailwind(entry) {
  const base = path.dirname(entry);
  const compiler = await compile(readFileSync(entry, "utf8"), { base, onDependency: () => {} });
  const declared = Array.isArray(compiler.sources) ? compiler.sources : [];
  const sources = declared.length
    ? declared
    : [base, path.resolve(base, "../../ui")].map((root) => ({ base: root, pattern: "**/*.{ts,tsx}", negated: false }));
  const css = compiler.build(new Scanner({ sources }).scan());
  if (!css.includes("@layer utilities")) throw new Error(`tailwind: ${entry} compiled no utilities layer`);
  return css;
}

/** esbuild: an imported `tailwind.css` is compiled, so `import "./tailwind.css"` works in both builds. */
export const tailwindPlugin = {
  name: "cmux-tailwind",
  setup(build) {
    build.onLoad({ filter: /[\\/]tailwind\.css$/ }, async (args) => ({
      contents: await compileTailwind(args.path),
      loader: "css",
    }));
  },
};
