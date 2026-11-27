const { build } = await import("vite");
await build({
  configFile: process.cwd() + "/vite.config.acpmux-pane.mjs",
  logLevel: "error",
  build: { outDir: "/tmp/x/panebuild", emptyOutDir: true, minify: false },
});
