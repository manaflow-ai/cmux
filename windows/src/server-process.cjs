const path = require("node:path");
const { createCmuxWindowsRuntime } = require("./server.cjs");

const runtime = createCmuxWindowsRuntime({
  staticDir: process.env.CMUX_WINDOWS_STATIC_DIR || path.join(__dirname, "..", "renderer")
});

runtime.listen().then((info) => {
  process.stdout.write(JSON.stringify({
    type: "ready",
    url: info.url,
    port: info.port,
    pipeName: info.pipeName,
    launchToken: info.launchToken,
    ptyAvailable: info.ptyAvailable
  }) + "\n");
}).catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});

function shutdown() {
  runtime.close();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
