#!/usr/bin/env tsx
import dotenv from "dotenv";
import fs from "fs/promises";
import { Instance, MorphCloudClient } from "morphcloud";
import path from "path";
import { io } from "socket.io-client";
import { fileURLToPath } from "url";

// Load environment variables
const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, ".env") });

async function runSSHCommand(
  instance: Instance,
  command: string,
  sudo = false,
  printOutput = true
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  const fullCommand =
    sudo && !command.startsWith("sudo ") ? `sudo ${command}` : command;

  console.log(`Running: ${fullCommand}`);
  const result = await instance.exec(fullCommand);

  if (printOutput) {
    if (result.stdout) {
      console.log(result.stdout);
    }
    if (result.stderr) {
      console.error(`ERR: ${result.stderr}`);
    }
  }

  if (result.exit_code !== 0) {
    console.log(`Command failed with exit code ${result.exit_code}`);
  }

  return {
    exitCode: result.exit_code,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

async function setupDockerWithBuildKit(instance: Instance) {
  console.log("\n--- Setting up Docker with BuildKit ---");

  // First, let's check what OS we're running on
  const osCheck = await runSSHCommand(
    instance,
    "cat /etc/os-release || echo 'Unknown OS'",
    true
  );
  console.log("OS Info:", osCheck.stdout);

  // Update package lists and install Docker
  await runSSHCommand(
    instance,
    "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io curl python3 make g++ bash nodejs npm",
    true
  );

  // Install Bun
  await runSSHCommand(
    instance,
    "curl -fsSL https://bun.sh/install | bash",
    true
  );

  // Enable BuildKit
  await runSSHCommand(
    instance,
    `mkdir -p /etc/docker && echo '{"features":{"buildkit":true}}' > /etc/docker/daemon.json && echo 'DOCKER_BUILDKIT=1' >> /etc/environment`,
    true
  );

  // Start Docker service
  await runSSHCommand(instance, "systemctl start docker", true);
  await runSSHCommand(instance, "systemctl enable docker", true);

  // Wait for Docker to be ready
  console.log("Waiting for Docker daemon to initialize...");
  for (let i = 0; i < 10; i++) {
    const result = await runSSHCommand(
      instance,
      "docker info >/dev/null 2>&1 && echo 'ready' || echo 'not ready'",
      true,
      false
    );
    if (result.stdout.includes("ready")) {
      console.log("Docker is ready");
      break;
    }
    console.log(`Waiting for Docker... (${i + 1}/10)`);
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
}

async function copyApplicationFiles(instance: Instance) {
  console.log("\n--- Copying application files ---");

  // Create the cmux directory structure
  await runSSHCommand(instance, "mkdir -p /cmux", true);

  // Instead of syncing large directories, let's create a tarball and transfer it
  const projectRoot = path.join(__dirname, "..");

  console.log("Creating tarball of project files...");

  // Create tarball excluding node_modules and other unnecessary files
  const { execSync } = await import("child_process");
  const tarballPath = path.join(__dirname, "cmux-files.tar.gz");

  try {
    // Create tarball with specific files we need
    execSync(
      `cd "${projectRoot}" && tar -czf "${tarballPath}" ` +
        `--exclude='node_modules' --exclude='.git' --exclude='dist' --exclude='build' ` +
        `apps packages package.json package-lock.json tsconfig.json`,
      { stdio: "inherit" }
    );

    console.log("Uploading tarball to instance...");
    // Upload the tarball
    await instance.sync(tarballPath, `${instance.id}:/tmp/cmux-files.tar.gz`);

    // Extract on the instance
    console.log("Extracting files on instance...");
    await runSSHCommand(
      instance,
      "cd /cmux && tar -xzf /tmp/cmux-files.tar.gz && rm /tmp/cmux-files.tar.gz",
      true
    );

    // Clean up local tarball
    await fs.unlink(tarballPath);
  } catch (error) {
    console.error("Error creating/transferring tarball:", error);
    // Fall back to copying essential files manually
    console.log("Falling back to manual file copy...");

    const filesToCopy = ["package.json", "package-lock.json"];
    for (const file of filesToCopy) {
      const srcPath = path.join(projectRoot, file);
      const destPath = `/cmux/${file}`;
      console.log(`Copying ${file}...`);
      try {
        const content = await fs.readFile(srcPath, "utf-8");
        await runSSHCommand(
          instance,
          `cat > ${destPath} << 'EOF'
${content}
EOF`,
          true
        );
      } catch (err) {
        console.log(`Skipping ${file}: ${err}`);
      }
    }
  }
}

async function buildWorkerWithBuildKit(instance: Instance) {
  console.log("\n--- Building worker with Bun ---");

  // Set up PATH for bun
  await runSSHCommand(
    instance,
    "export PATH=/root/.bun/bin:$PATH && cd /cmux && npm install",
    true
  );

  // Create builtins directory
  await runSSHCommand(instance, "mkdir -p /builtins", true);

  // Build the worker
  await runSSHCommand(
    instance,
    "export PATH=/root/.bun/bin:$PATH && bun build /cmux/apps/worker/src/index.ts --target node --outdir /builtins/build",
    true
  );

  // Copy necessary files to builtins
  await runSSHCommand(
    instance,
    "cp /cmux/apps/worker/package.json /builtins/package.json",
    true
  );

  // Copy wait-for-docker.sh
  await runSSHCommand(
    instance,
    "cp /cmux/worker-scripts/wait-for-docker.sh /usr/local/bin/ && chmod +x /usr/local/bin/wait-for-docker.sh",
    true
  );

  // Create workspace directory
  await runSSHCommand(instance, "mkdir -p /workspace", true);
}

async function createStartupScript(instance: Instance) {
  console.log("\n--- Creating startup script ---");

  const startupScript = `#!/bin/sh
dockerd-entrypoint.sh &
wait-for-docker.sh
cd /builtins
NODE_ENV=production WORKER_PORT=39377 node /builtins/build/index.js
`;

  await runSSHCommand(
    instance,
    `cat > /startup.sh << 'EOF'
${startupScript}
EOF`,
    true
  );

  await runSSHCommand(instance, "chmod +x /startup.sh", true);
}

async function createDockerfile(instance: Instance) {
  console.log("\n--- Creating Dockerfile for BuildKit ---");

  const dockerfile = `# syntax=docker/dockerfile:1.4
FROM docker:28.3.2-dind

# Build and runtime dependencies
RUN apk add --no-cache \\
    curl python3 make g++ linux-headers bash \\
    nodejs npm

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# Application source
COPY . /cmux
WORKDIR /cmux

# Install Node deps and build the worker
RUN npm install

RUN ls /cmux
RUN ls /cmux/apps/worker

RUN bun build /cmux/apps/worker/src/index.ts --target node --outdir /cmux/apps/worker/build

# Move artefacts to runtime location
RUN mkdir -p /builtins && \\
    cp -r ./apps/worker/build /builtins/build && \\
    cp ./apps/worker/package.json /builtins/package.json && \\
    cp ./worker-scripts/wait-for-docker.sh /usr/local/bin/ && \\
    chmod +x /usr/local/bin/wait-for-docker.sh

# Workspace
RUN mkdir -p /workspace
WORKDIR /builtins

# Environment
ENV NODE_ENV=production
ENV WORKER_PORT=39377

# Ports
EXPOSE 39375 39377

# Startup script
RUN cat > /startup.sh << 'EOF'
#!/bin/sh
dockerd-entrypoint.sh &
wait-for-docker.sh
node /builtins/build/index.js
EOF
RUN chmod +x /startup.sh

ENTRYPOINT ["/startup.sh"]
CMD []
`;

  await runSSHCommand(
    instance,
    `cat > /cmux/Dockerfile << 'EOF'
${dockerfile}
EOF`,
    true
  );
}

async function buildAndTestDocker(instance: Instance) {
  console.log("\n--- Building Docker image with BuildKit ---");

  // Build the Docker image
  const buildResult = await runSSHCommand(
    instance,
    "cd /cmux && DOCKER_BUILDKIT=1 docker build --progress=plain -t cmux-worker:latest .",
    true
  );

  if (buildResult.exitCode !== 0) {
    throw new Error("Failed to build Docker image");
  }

  console.log("\n--- Testing Docker container ---");

  // Run a test container
  const runResult = await runSSHCommand(
    instance,
    "docker run -d --privileged -p 39377:39377 --name test-worker cmux-worker:latest",
    true
  );

  if (runResult.exitCode !== 0) {
    throw new Error("Failed to run Docker container");
  }

  // Wait for container to start
  await new Promise((resolve) => setTimeout(resolve, 5000));

  // Check if container is running
  const psResult = await runSSHCommand(
    instance,
    "docker ps --filter name=test-worker --format '{{.Status}}'",
    true
  );

  console.log("Container status:", psResult.stdout);

  // Stop and remove test container
  await runSSHCommand(
    instance,
    "docker stop test-worker && docker rm test-worker",
    true
  );
}

async function startWorkerDirectly(instance: Instance) {
  console.log("\n--- Starting worker directly for testing ---");

  // Start the worker process in the background
  await runSSHCommand(
    instance,
    "cd /builtins && NODE_ENV=production WORKER_PORT=39377 nohup node /builtins/build/index.js > /tmp/worker.log 2>&1 &",
    true
  );

  // Expose HTTP services
  await instance.exposeHttpService("worker", 39377);

  console.log("Worker started, services exposed");
}

async function testWorkerConnection(instance: Instance) {
  console.log("\n--- Testing worker connection ---");

  // Get the instance networking info to find the exposed URLs
  const client = new MorphCloudClient();
  const freshInstance = await client.instances.get({ instanceId: instance.id });

  let managementUrl: string | null = null;
  let workerUrl: string | null = null;

  for (const service of freshInstance.networking.httpServices) {
    if (service.name === "management") {
      managementUrl = service.url;
    } else if (service.name === "worker") {
      workerUrl = service.url;
    }
  }

  if (!managementUrl || !workerUrl) {
    throw new Error("Could not find exposed service URLs");
  }

  console.log("Management URL:", managementUrl);
  console.log("Worker URL:", workerUrl);

  // Test socket.io connection
  const managementSocket = io(managementUrl);

  return new Promise<void>((resolve, reject) => {
    managementSocket.on("connect", () => {
      console.log("Connected to worker management port");
    });

    managementSocket.on("worker:register", (data: unknown) => {
      console.log("Worker registered:", data);

      // Test creating a terminal
      managementSocket.emit("worker:create-terminal", {
        terminalId: "test-terminal-1",
        cols: 80,
        rows: 24,
        cwd: "/",
      });
    });

    managementSocket.on("worker:terminal-created", (data: unknown) => {
      console.log("Terminal created:", data);

      // Test sending input
      managementSocket.emit("worker:terminal-input", {
        terminalId: "test-terminal-1",
        data: 'echo "Hello from MorphCloud worker!"\\r',
      });
    });

    managementSocket.on("worker:terminal-output", (data: { data: string }) => {
      console.log("Terminal output:", data);

      if (data.data.includes("Hello from MorphCloud worker!")) {
        console.log("Test successful!");
        managementSocket.disconnect();
        resolve();
      }
    });

    managementSocket.on("error", (error: unknown) => {
      console.error("Socket error:", error);
      reject(error);
    });

    // Timeout after 30 seconds
    setTimeout(() => {
      managementSocket.disconnect();
      reject(new Error("Test timed out"));
    }, 30000);
  });
}

async function main() {
  try {
    const client = new MorphCloudClient();

    // Configuration
    const VCPUS = 4;
    const MEMORY = 4096;
    const DISK_SIZE = 8192;

    console.log("Creating initial snapshot with minimal base image...");
    const initialSnapshot = await client.snapshots.create({
      imageId: "morphvm-minimal", // Use minimal base image
      vcpus: VCPUS,
      memory: MEMORY,
      diskSize: DISK_SIZE,
    });

    console.log(`Starting instance from snapshot ${initialSnapshot.id}...`);
    const instance = await client.instances.start({
      snapshotId: initialSnapshot.id,
    });

    // Wait for instance to be ready
    await instance.waitUntilReady();

    try {
      // Set up Docker with BuildKit
      await setupDockerWithBuildKit(instance);

      // Copy application files
      await copyApplicationFiles(instance);

      // Build the worker
      await buildWorkerWithBuildKit(instance);

      // Create startup script
      await createStartupScript(instance);

      // Create Dockerfile
      await createDockerfile(instance);

      // Build and test Docker image
      await buildAndTestDocker(instance);

      // Start worker directly for testing
      await startWorkerDirectly(instance);

      // Wait for worker to initialize
      await new Promise((resolve) => setTimeout(resolve, 5000));

      // Test worker connection
      await testWorkerConnection(instance);

      // Create final snapshot
      console.log("\n--- Creating final snapshot ---");
      const finalSnapshot = await instance.snapshot({
        metadata: {
          name: `cmux-worker-${Date.now()}`,
          description: "cmux worker with Docker BuildKit support",
        },
      });

      console.log(`\n✅ Successfully created snapshot: ${finalSnapshot.id}`);
      console.log("\nTo use this snapshot:");
      console.log(
        `  const instance = await client.instances.start({ snapshotId: "${finalSnapshot.id}" });`
      );

      // Display instance information
      console.log("\nInstance Details:");
      console.log(`  ID: ${instance.id}`);
      console.log(`  Snapshot ID: ${finalSnapshot.id}`);
      console.log("\nHTTP Services:");
      const freshInstance = await client.instances.get({
        instanceId: instance.id,
      });
      for (const service of freshInstance.networking.httpServices) {
        console.log(`  ${service.name}: ${service.url}`);
      }
    } finally {
      // Stop the instance
      console.log("\nStopping instance...");
      await instance.stop();
    }
  } catch (error) {
    console.error("Error:", error);
    process.exit(1);
  }
}

// Run the main function
main().catch((error) => {
  console.error("Unhandled error:", error);
  process.exit(1);
});
