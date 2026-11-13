import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

/** Emit module attribution for the shipped Rolldown outputs without a visualizer dependency. */
export function bundleMetafile(file) {
  return {
    name: "cmux-bundle-metafile",
    async generateBundle(_options, bundle) {
      if (!file) return;
      const outputs = {};
      for (const [fileName, item] of Object.entries(bundle)) {
        const source = item.type === "asset" ? item.source : item.code;
        const bytes = Buffer.byteLength(typeof source === "string" ? source : (source ?? ""));
        const inputs = {};
        if (item.type === "chunk") {
          for (const [moduleId, module] of Object.entries(item.modules)) {
            inputs[moduleId] = {
              // Rolldown exposes module sizes before the final chunk minifier.
              // Keep these separate from the emitted output bytes above: the
              // latter is the only byte count suitable for shipped-size claims.
              sourceBytes: module.originalLength ?? null,
              renderedBytes: module.renderedLength ?? null,
              // Retained for readers of schema 1; report.py uses the explicit
              // metric below and never treats this as emitted bytes.
              bytes: module.originalLength ?? module.renderedLength ?? 0,
              bytesInOutput: module.renderedLength ?? module.originalLength ?? 0,
              metric: "rolldown-rendered-pre-minification",
            };
          }
        }
        outputs[fileName] = {
          bytes,
          entryPoint: item.type === "chunk" ? (item.facadeModuleId ?? null) : null,
          imports: item.type === "chunk" ? item.imports : [],
          dynamicImports: item.type === "chunk" ? item.dynamicImports : [],
          inputs,
        };
      }
      await mkdir(path.dirname(file), { recursive: true });
      await writeFile(file, JSON.stringify({ schema: 2, tool: "rolldown", outputs }));
    },
  };
}
