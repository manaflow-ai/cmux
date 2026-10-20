import { expect, test } from "bun:test";
import { build } from "esbuild";
import path from "node:path";
import { reactCompilerPlugin } from "../scripts/agent-pane/reactCompilerPlugin.mjs";

for (const [file, name] of [
  ["FilesView.tsx", "FilesView"],
  ["useChatViewer.ts", "useChatViewer"],
]) {
  test(`${name} compiles without falling back from React Compiler optimization`, async () => {
    const srcRoot = path.resolve(import.meta.dir, "../src");
    const relative = `agent-session/acpmux/${file}`;
    const compiled = new Set<string>();
    const diagnostics: object[] = [];
    await build({
      entryPoints: [path.join(srcRoot, relative)],
      bundle: true,
      packages: "external",
      format: "esm",
      platform: "browser",
      write: false,
      logLevel: "silent",
      plugins: [
        reactCompilerPlugin({
          mode: "babel",
          srcRoot,
          onCompiled: (id: string) => compiled.add(id),
          onDiagnostic: (diagnostic: { file: string }) => {
            if (diagnostic.file === relative) diagnostics.push(diagnostic);
          },
        }),
      ],
    });
    expect(diagnostics).toEqual([]);
    expect(compiled.has(`${relative}:${name}`)).toBe(true);
  });
}
