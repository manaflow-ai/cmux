// The `define` every production esbuild bundle uses: `process.env.NODE_ENV` and the
// `import.meta.env` Vite's production build substitutes. esbuild leaves `import.meta.env` as
// written, and in the app's pages it is undefined at run time: `import.meta.env.DEV` in the
// agent pane threw on every handshake (cmux#50616, fixed by cmux#51194).
// scripts/cmux-next/check-bundle-import-meta-env.py fails a build whose output still has one.
// The esbuild CLI build of Agent Activity (build-agent-activity-web.sh) passes the
// same object to --define.
export const productionImportMetaEnv = { BASE_URL: "/", DEV: false, MODE: "production", PROD: true, SSR: false };

export const productionDefine = {
  "process.env.NODE_ENV": '"production"',
};
