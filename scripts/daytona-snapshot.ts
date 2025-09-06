import { Daytona, Image } from "@daytonaio/sdk";
import { execSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { connectToWorkerManagement } from "@cmux/shared/socket";

try {
  const daytona = new Daytona();

  // fake the cwd to be worker dir
  // process.chdir(path.join(import.meta.dirname, ".."));

  // make a copy of the entire dir in a /tmp dir, using git ls-files to respect gitignore
  const tmpDir = path.join(os.tmpdir(), "cmux");

  // Remove existing tmp dir if it exists
  if (fs.existsSync(tmpDir)) {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }

  // Create the tmp directory
  fs.mkdirSync(tmpDir, { recursive: true });

  // Get list of tracked files from git
  const gitFiles = execSync("git ls-files", { encoding: "utf8" })
    .trim()
    .split("\n")
    .filter(Boolean);

  // Copy each tracked file
  let totalSize = 0;
  for (const file of gitFiles) {
    const srcPath = path.resolve(file);
    const destPath = path.join(tmpDir, file);

    // Create directory if it doesn't exist
    const destDir = path.dirname(destPath);
    if (!fs.existsSync(destDir)) {
      fs.mkdirSync(destDir, { recursive: true });
    }

    // Copy the file
    fs.copyFileSync(srcPath, destPath);

    // Add to total size
    const stats = fs.statSync(destPath);
    totalSize += stats.size;
  }

  // Format size in human readable format
  const formatSize = (bytes: number) => {
    const units = ["B", "KB", "MB", "GB"];
    let size = bytes;
    let unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return `${size.toFixed(2)} ${units[unitIndex]}`;
  };

  console.log(
    `copied ${gitFiles.length} tracked files (${formatSize(totalSize)}) to`,
    tmpDir
  );

  const image = Image.fromDockerfile(path.join(tmpDir, "Dockerfile"));
  // const image = Image.base("docker:28.3.2-dind")
  //   .runCommands(
  //     "apk add --no-cache curl python3 make g++ linux-headers bash nodejs npm"
  //   )
  //   .runCommands("which npm && npm --version")
  //   .runCommands("curl -fsSL https://bun.sh/install | bash")
  //   .runCommands("which bun && bun --version")
  //   .addLocalDir("apps", "/cmux/apps")
  //   .addLocalDir("packages", "/cmux/packages")
  //   .addLocalFile("package.json", "/cmux/package.json")
  //   .addLocalFile("package-lock.json", "/cmux/package-lock.json")
  //   .runCommands("npm install")
  //   .env({
  //     PATH: "/root/.bun/bin:$PATH",
  //   })
  //   .runCommands("mkdir -p /builtins")
  //   .runCommands(
  //     "bun build /cmux/apps/worker/src/index.ts --target node --outdir /builtins/build"
  //   )
  //   .runCommands("cp -r /cmux/apps/worker/build /builtins/build")
  //   .addLocalFile(
  //     "apps/worker/wait-for-docker.sh",
  //     "/usr/local/bin/wait-for-docker.sh"
  //   )
  //   .addLocalFile("apps/worker/start-up.sh", "/usr/local/bin/startup.sh")
  //   .runCommands("mkdir -p /workspace")
  //   .env({
  //     NODE_ENV: "production",
  //     WORKER_PORT: "39377",
  //   })
  //   .entrypoint(["/startup.sh"]);

  // console.log("skibidi");
  // const fk = await daytona.snapshot.create(
  //   {
  //     name: `cmux-worker-${Date.now()}`,
  //     image,
  //   },
  //   { onLogs: console.log, timeout: 10000 }
  // );
  // console.log("snapshot created", fk);

  console.log("starting sandbox");
  const sandbox = await daytona.create(
    {
      image,
      public: true,
    },
    {
      onSnapshotCreateLogs: console.log,
      timeout: 10000,
    }
  );

  async function runCommand(command: string) {
    const response = await sandbox.process.executeCommand(command);
    console.log(response.result);
    return response.result;
  }

  // Wait for Docker to fully initialize
  console.log("Waiting for Docker daemon to initialize...");
  const now = Date.now();
  await runCommand("wait-for-docker.sh");
  console.log(`Docker daemon is ready after ${Date.now() - now}ms`);

  // Test Docker functionality
  await runCommand("docker --version");
  await runCommand("docker-compose --version");

  // Verify devcontainer CLI is installed
  await runCommand("devcontainer --version");

  const { url } = await sandbox.getPreviewLink(39377);

  const managementSocket = connectToWorkerManagement({ url });

  managementSocket.on("connect", () => {
    console.log("Connected to worker management port");
  });

  managementSocket.on("worker:register", (data) => {
    console.log("Worker registered:", data);

    // Test creating a terminal
    managementSocket.emit("worker:create-terminal", {
      terminalId: "test-terminal-1",
      cols: 80,
      rows: 24,
      cwd: "/",
    });
  });

  managementSocket.on("worker:terminal-created", (data) => {
    console.log("Terminal created:", data);

    // Test sending input
    managementSocket.emit("worker:terminal-input", {
      terminalId: "test-terminal-1",
      data: 'echo "Hello from worker!"\r',
    });
  });

  managementSocket.on("worker:terminal-output", (data) => {
    console.log("Terminal output:", data);

    // Exit after seeing output
    if (data.data.includes("Hello from worker!")) {
      console.log("Test successful!");
      setTimeout(() => {
        managementSocket.disconnect();
        clientSocket.disconnect();
        process.exit(0);
      }, 1000);
    }
  });

  managementSocket.on("worker:heartbeat", (data) => {
    console.log("Worker heartbeat:", data);
  });

  managementSocket.on("error", (error) => {
    console.error("Socket error:", error);
  });

  // Also test client connection
  const clientSocket = io("http://localhost:39377/vscode");

  clientSocket.on("connect", () => {
    console.log("Connected to worker client port");
  });

  clientSocket.on("terminal-created", (data) => {
    console.log("Client: Terminal created:", data);
  });

  clientSocket.on("terminal-output", (data) => {
    console.log("Client: Terminal output:", data.data);
  });

  // Graceful shutdown
  process.on("SIGINT", () => {
    console.log("Shutting down test client...");
    managementSocket.disconnect();
    clientSocket.disconnect();
    process.exit(0);
  });
} catch (error) {
  console.error(error);
  process.exit(1);
}
