const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const pipeName = process.env.CMUX_WINDOWS_PIPE || (
  process.platform === "win32"
    ? "\\\\.\\pipe\\cmux-windows"
    : path.join(os.tmpdir(), "cmux-windows.sock")
);

const args = process.argv.slice(2);
if (args[0] === "help" || args[0] === "--help" || args[0] === "-h") {
  process.stdout.write(`cmuxw commands:
  ping
  list-workspaces
  reset-session
  new-workspace <name>
  new-terminal
  restart-terminal
  browser-open <url>
  notify <message>
  send <text>
`);
  process.exit(0);
}
const command = args.length > 0 ? args.join(" ") : "ping";

const socket = net.createConnection(pipeName);
let output = "";

socket.on("connect", () => {
  socket.write(command + "\n");
});

socket.on("data", (chunk) => {
  output += chunk.toString("utf8");
  if (output.includes("\n")) {
    process.stdout.write(output);
    socket.end();
  }
});

socket.on("error", (error) => {
  process.stderr.write(`cmuxw: connection_failed ${pipeName}\n`);
  process.exitCode = 1;
});
