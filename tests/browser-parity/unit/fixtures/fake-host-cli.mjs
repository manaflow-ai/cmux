#!/usr/bin/env node
// Stand-in for the cmux-browser-host CLI (unit/bench-host.test.mjs).
// `serve --socket S` listens on S until it is stopped; any other command
// records the host socket it was given. Both append a line to $FAKE_HOST_LOG.
import fs from "node:fs";
import net from "node:net";

const cmd = process.argv[2];
const log = (row) => fs.appendFileSync(process.env.FAKE_HOST_LOG, JSON.stringify(row) + "\n");
if (cmd === "serve") {
  const socket = process.argv[process.argv.indexOf("--socket") + 1];
  log({ serve: process.pid, socket });
  net.createServer((c) => c.end()).listen(socket);
} else {
  log({ cmd, socket: process.env.CMUX_BROWSER_HOST_SOCKET || null });
}
