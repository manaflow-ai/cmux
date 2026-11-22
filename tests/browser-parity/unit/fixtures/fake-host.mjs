// Stand-in for `cmux-browser-host serve --socket S` (unit/parity-host.test.mjs):
// listens on S until it is stopped.
import net from "node:net";

const at = process.argv.indexOf("--socket");
net.createServer((c) => c.end()).listen(process.argv[at + 1]);
