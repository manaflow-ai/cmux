// gdp-ts preset in strict mode: proofs are minted only in src/proofs/, provers
// are never exported, and no `as` or `any` outside src/proofs/ and
// src/lib/ids.ts can forge one.
//
// gdp-ts ships TypeScript sources and Node will not strip types under
// node_modules, so `bun run lint:prepare` compiles the preset and its plugin
// from the pinned commit into .gdp-lint/ first; nothing is changed.
import gdp from "./.gdp-lint/oxlint.js";

const preset = gdp({ strict: true, proofs: ["src/proofs/**"], allowAssertions: ["src/lib/ids.ts"] });

export default {
  ...preset,
  jsPlugins: preset.jsPlugins.map((plugin) => ({ ...plugin, specifier: "./.gdp-lint/plugin.js" })),
};
