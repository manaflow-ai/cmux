import { bindings, defineConfig, defineWorker, exports } from "@cloudflare/config";

const worker = defineWorker({
  name: "mux-staging",
  compatibilityDate: "2026-09-30",
  compatibilityFlags: ["nodejs_compat"],
  entrypoint: "./src/index.ts",
  assets: { notFoundHandling: "single-page-application", runWorkerFirst: ["/api/*"] },
  exports: {
    AccountDO: exports.durableObject({ storage: "sqlite" }),
    ConversationDO: exports.durableObject({ storage: "sqlite" }),
    MuxDO: exports.durableObject({ storage: "sqlite" }),
    MuxApi: exports.worker(),
  },
  env: {
    ACCOUNT: bindings.durableObject({ worker: "mux-staging", exportName: "AccountDO" }),
    CONVERSATION: bindings.durableObject({ worker: "mux-staging", exportName: "ConversationDO" }),
    MUX: bindings.durableObject({ worker: "mux-staging", exportName: "MuxDO" }),
    LOADER: bindings.workerLoader(),
    ASSETS: bindings.assets(),
    CODEROUTER_API_KEY: bindings.secret(),
    FREESTYLE_API_KEY: bindings.secret(),
    // BusyBox + git, 1 vCPU / 128 MiB / 1 GB (scripts/bake-memory-snapshot.ts).
    MUX_MEMORY_SNAPSHOT: bindings.text("mux-memory-base"),
    MUX_DEV_AUTH: bindings.secret(),
    // cmux development Stack project (cmuxterm-dev). Switching to the production
    // project needs OAuth redirect domains added there; see DESIGN.md.
    MUX_STACK_PROJECT_ID: bindings.text("454ecd03-1db2-4050-845e-4ce5b0cd9895"),
    MUX_STACK_PUBLISHABLE_CLIENT_KEY: bindings.secret(),
  },
});

export default defineConfig({ accountId: "0c1675e0def6de1ab3a50a4e17dc5656", worker });
