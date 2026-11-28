// gdp-ts preset in strict mode: proofs are minted only in src/proofs/, provers
// are never exported, and no `as` or `any` outside src/proofs/ and
// src/lib/ids.ts can forge one.
//
// gdp-ts ships TypeScript sources and Node will not strip types under
// node_modules, so `bun run lint:prepare` compiles the preset and its plugin
// from the pinned commit into .gdp-lint/ first; nothing is changed.
//
// Two more boundaries, checked by scripts/lint-selftest.sh like the preset:
// - network access (`fetch`) only in src/upstream/ and src/auth/;
// - the upstream implementation (src/upstream/live.ts and live-*.ts: the
//   clients that hold the provider key) is imported only from src/upstream/, src/proofs/ and the
//   composition root src/index.ts. Tests are outside this rule; they build the
//   client with a fake fetch and a fake key.
import gdp from "./.gdp-lint/oxlint.js";

const preset = gdp({ strict: true, proofs: ["src/proofs/**"], allowAssertions: ["src/lib/ids.ts"] });

const guarded = ["src/**/*.ts", "lint-fixtures/**/*.ts"];

export default {
  ...preset,
  jsPlugins: preset.jsPlugins.map((plugin) => ({ ...plugin, specifier: "./.gdp-lint/plugin.js" })),
  overrides: [
    ...preset.overrides,
    {
      files: guarded,
      rules: {
        "no-restricted-globals": ["error", "fetch"],
        "no-restricted-imports": [
          "error",
          {
            patterns: [
              {
                regex: "(^|/)upstream/live(-[a-z0-9-]+)?(\\.ts)?$",
                message: "The upstream implementation holds the provider key; import UpstreamClient from upstream/client.ts.",
              },
            ],
          },
        ],
      },
    },
    { files: ["src/upstream/**", "src/auth/**"], rules: { "no-restricted-globals": "off" } },
    { files: ["src/upstream/**", "src/proofs/**", "src/index.ts"], rules: { "no-restricted-imports": "off" } },
  ],
};
