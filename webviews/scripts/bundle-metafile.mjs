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
              bytes: module.originalLength ?? module.renderedLength ?? 0,
              bytesInOutput: module.renderedLength ?? module.originalLength ?? 0,
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
      await writeFile(file, JSON.stringify({ schema: 1, tool: "rolldown", outputs }));
    },
  };
}
