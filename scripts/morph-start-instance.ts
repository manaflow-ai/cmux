import type { ServerToWorkerEvents, WorkerToServerEvents } from "@cmux/shared";
import { MorphCloudClient } from "morphcloud";
import readline from "readline";
import { connectToWorkerManagement, type Socket } from "@cmux/shared/socket";

const client = new MorphCloudClient();

console.log("Starting instance");
const instance = await client.instances.start({
  // snapshotId: "snapshot_hzlmd4kx",
  snapshotId: "snapshot_g9klz9c4",
  // 30 minutes
  ttlSeconds: 60 * 60 * 2,
  ttlAction: "pause",
  metadata: {
    app: "cmux-dev",
  },
});

const vscodeUrl = instance.networking.httpServices.find(
  (service) => service.port === 39378
)?.url;
if (!vscodeUrl) {
  throw new Error("VSCode URL not found");
}
console.log(`VSCode URL: ${vscodeUrl}`);
const url = `${vscodeUrl}/?folder=/root/workspace`;
console.log(`VSCode Workspace URL: ${url}`);

process.on("SIGINT", async () => {
  console.log("Stopping instance");
  try {
    await instance.stop();
  } catch (error) {
    console.error("Error stopping instance", error);
  }
  process.exit(0);
});

// await new Promise(() => void {});

console.log(`Created instance: ${instance.id}`);

const portsToExpose = [
  5173,
  9777,
  9778,
  6791,
  39378,
  39377,
  39379,
  39380,
  39381,
  39383,
];
console.log("Exposing ports", portsToExpose);
await Promise.all(
  portsToExpose.map((port) => instance.exposeHttpService(`port-${port}`, port))
);

console.log("Exposed services");
const exposedServices = instance.networking.httpServices;
console.log(exposedServices);
const vscodeService = exposedServices.find((service) => service.port === 39378);
const workerService = exposedServices.find((service) => service.port === 39377);
const proxyService = exposedServices.find((service) => service.port === 39379);
const vncService = exposedServices.find((service) => service.port === 39380);
const cdpService = exposedServices.find((service) => service.port === 39381);
if (!vscodeService || !workerService || !proxyService || !vncService || !cdpService) {
  throw new Error("VSCode, worker, proxy, VNC, or DevTools service not found");
}

console.log(`VSCode: ${vscodeService.url}/?folder=/root/workspace`);
console.log(`Proxy: ${proxyService.url}`);
console.log(`VNC: ${vncService.url}/vnc.html`);
console.log(`DevTools: ${cdpService.url}/json/version`);

console.log("Connecting to worker...");

console.log("workerService.url", workerService.url);

// press enter to snapshot

await new Promise((resolve) => {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  rl.question("Press Enter to snapshot...", () => {
    rl.close();
    resolve(true);
  });
});

const snapshot = await instance.snapshot();
console.log("Snapshot", snapshot.id);

// just wait here until user presses enter

await new Promise((resolve) => {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  rl.question("Press Enter to continue...", () => {
    rl.close();
    resolve(true);
  });
});

const workerUrl = new URL(workerService.url);
workerUrl.pathname = "/management";

console.log("workerUrl", workerUrl.toString());

// connect to the worker management namespace with socketio
const clientSocket = connectToWorkerManagement({
  url: workerService.url,
  timeoutMs: 10_000,
  reconnectionAttempts: 3,
  forceNew: true,
});

clientSocket.on("disconnect", () => {
  console.log("Disconnected from worker");
  process.exit(1);
});
await new Promise((resolve, reject) => {
  clientSocket.on("connect_error", (err) => {
    console.error("Failed to connect to worker", err);
    reject(err);
  });

  clientSocket.on("connect", () => {
    console.log("Connected to worker!");
    resolve(true);
  });
});

async function workerExec({
  workerSocket,
  command,
  args,
  cwd,
  env,
}: {
  workerSocket: Socket<WorkerToServerEvents, ServerToWorkerEvents>;
  command: string;
  args: string[];
  cwd: string;
  env: Record<string, string>;
}) {
  return new Promise((resolve, reject) => {
    workerSocket.emit("worker:exec", { command, args, cwd, env }, (payload) => {
      if (payload.error) {
        reject(payload.error);
      } else {
        resolve(payload);
      }
    });
  });
}

console.log("Install dependencies + dev.sh");
await workerExec({
  workerSocket: clientSocket,
  command: "bash",
  args: ["-c", "SKIP_DOCKER_BUILD=true SKIP_CONVEX=true ./scripts/dev.sh"],
  cwd: "/root/workspace",
  env: {},
});
// await workerExec({
//   workerSocket: clientSocket,
//   command: "git",
//   args: [
//     "clone",
//     "--depth=1",
//     "https://github.com/manaflow-ai/cmux",
//     "/root/workspace",
//   ],
//   cwd: "/root",
//   env: {},
// });

// then start tmux

// await workerExec({
//   workerSocket: clientSocket,
//   command: "tmux",
//   args: ["new-session", "-s", "cmux", "-d"],
//   cwd: "/root/workspace",
//   env: {},
// });

// then we

console.log("Press Ctrl+C to stop instance");
await new Promise(() => void {});
