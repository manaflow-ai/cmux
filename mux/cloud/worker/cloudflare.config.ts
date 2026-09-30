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
    MUX_DEV_AUTH: bindings.secret(),
  },
});

export default defineConfig({ accountId: "0c1675e0def6de1ab3a50a4e17dc5656", worker });
