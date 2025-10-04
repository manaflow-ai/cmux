import { startServer } from "@cmux/server";
import { Command } from "commander";
import { existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ConvexProcesses, spawnConvex } from "./convex/spawnConvex";
import { ensureBundleExtracted } from "./convex/ensureBundleExtracted";
import { deployConvexFunctions } from "./convex/deployConvex";
import { ensureLogFiles } from "./ensureLogFiles";
import { logger } from "./logger";
import { checkPorts } from "./utils/checkPorts";
import { getGitRepoInfo } from "./utils/gitUtils";
import { killPortsIfNeeded } from "./utils/killPortsIfNeeded";
import { checkDockerStatus } from "./utils/checkDocker";

const versionPadding = " ".repeat(Math.max(0, 14 - VERSION.toString().length));
console.log("\n\x1b[36m╔══════════════════════════════════════╗\x1b[0m");
console.log(
  `\x1b[36m║      Welcome to \x1b[1m\x1b[37mcmux\x1b[0m\x1b[36m v${VERSION}!${versionPadding}║\x1b[0m`
);
console.log("\x1b[36m╚══════════════════════════════════════╝\x1b[0m\n");
console.log("\x1b[32m✓\x1b[0m Server starting...");

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const convexDir = path.resolve(homedir(), ".cmux");

// When running as a compiled binary, __dirname might be in a virtual filesystem
// Check if we're in a bundled environment
const isBundled = __dirname.includes("/$bunfs/");

let staticDir: string;
if (isBundled) {
  // In bundled mode, always use the extracted files from ~/.cmux
  staticDir = path.resolve(convexDir, "public", "dist");
} else {
  // In development mode, use the normal path
  staticDir = path.resolve(__dirname, "..", "public", "dist");
}

const program = new Command();

declare const VERSION: string;

const cleanupFunctions: (() => Promise<void>)[] = [];

const status = {
  convexReady: false,
  serverReady: false,
};

// wait 5 seconds, if not ready, log error to console
setTimeout(async () => {
  if (status.convexReady && status.serverReady) {
    return;
  }
  console.log(
    "\x1b[31m✗\x1b[0m Server failed to start after 30 seconds. Please email founders@manaflow.com with the contents of ~/.cmux/logs/*"
  );
  await logger.info(
    `Server failed to start after 30 seconds. convexReady=${status.convexReady} serverReady=${status.serverReady}`
  );
  process.exit(1);
}, 30_000);

// Register exit handlers immediately
process.on("SIGINT", async () => {
  void Promise.all(cleanupFunctions.map((fn) => fn()));
  setImmediate(() => void {});
  process.exit(0);
});

process.on("SIGTERM", async () => {
  void Promise.all(cleanupFunctions.map((fn) => fn()));
  setImmediate(() => void {});
  process.exit(0);
});

program
  .name("cmux")
  .description("Socket.IO and static file server")
  .version(VERSION)
  .argument("[path]", "path to git repository (defaults to current directory)")
  .option("-p, --port <port>", "port to listen on", "9776")
  .option("-c, --cors <origin>", "CORS origin configuration", "true")
  .option(
    "--no-autokill-ports",
    "disable automatic killing of processes on required ports"
  )
  .action(async (repoPath, options) => {
    // Ensure Docker is installed and the daemon is running before proceeding
    let announcedDockerWait = false;
    const dockerStatus = await checkDockerStatus({
      onRetry: (attempt) => {
        if (!announcedDockerWait && attempt === 1) {
          console.log(
            "\x1b[33m…\x1b[0m Waiting for Docker to become available before continuing"
          );
          announcedDockerWait = true;
        }
      },
    });
    if (dockerStatus !== "ok") {
      const isMac = process.platform === "darwin";
      if (dockerStatus === "not_installed") {
        console.log("\x1b[33m⚠\x1b[0m Docker is not installed.");
        if (isMac) {
          console.log(
            "\nInstall one of the following and relaunch cmux:\n" +
              "  • \x1b[36mbrew install --cask orbstack\x1b[0m  (recommended — more battery efficient)\n" +
              "  • \x1b[36mbrew install docker\x1b[0m\n"
          );
        } else {
          console.log(
            "\nPlease install Docker Engine or a Docker Desktop alternative, then relaunch cmux."
          );
        }
        process.exit(1);
      }

      if (dockerStatus === "not_running") {
        console.log(
          "\x1b[33m⚠\x1b[0m Docker is installed but the daemon is not running."
        );
        if (isMac) {
          console.log(
            "\nStart \x1b[36mOrbStack\x1b[0m or \x1b[36mDocker Desktop\x1b[0m, then relaunch cmux.\n"
          );
        } else {
          console.log("\nStart the Docker daemon, then relaunch cmux.\n");
        }
        process.exit(1);
      }
    }

    const port = parseInt(options.port);

    if (repoPath) {
      console.log(`\x1b[36m→\x1b[0m Repository path provided: ${repoPath}`);
    }

    const portsToCheck = [port, 9777, 9778];
    if (options.autokillPorts) {
      // log how long it takes to kill ports
      const startTime = Date.now();
      await killPortsIfNeeded(portsToCheck);
      const endTime = Date.now();
      const duration = endTime - startTime;
      await logger.info(`Ports killed in ${duration}ms`);
    } else {
      // Manual check without killing
      const startTime = Date.now();
      const portsInUse = await checkPorts(portsToCheck);
      const endTime = Date.now();
      const duration = endTime - startTime;
      await logger.info(`Ports checked in ${duration}ms`);
      if (portsInUse.length > 0) {
        console.error("\x1b[31m✗\x1b[0m Ports already in use:");
        console.error(portsInUse.map((p) => `  - ${p}`).join("\n"));
        console.log(
          "\nYou can either:\n" +
            "  1. Run with default behavior to auto-kill: \x1b[36mcmux\x1b[0m\n" +
            "  2. Manually kill the processes: \x1b[90m" +
            `for p in ${portsInUse.join(" ")}; do lsof -ti :$p | xargs -r kill -9; done\x1b[0m`
        );
        process.exit(1);
      }
    }

    ensureLogFiles();

    // Ensure bundled assets are extracted early so static files exist
    let didExtract = false;
    try {
      const res = await ensureBundleExtracted(convexDir);
      didExtract = res.didExtract;
    } catch (e) {
      await logger.error(`Failed to extract bundled assets: ${e}`);
      console.error("Failed to extract bundled assets:", e);
      process.exit(1);
    }

    // Start Convex backend
    let convexProcessesPromise: Promise<ConvexProcesses>;
    try {
      convexProcessesPromise = spawnConvex(convexDir).then(
        async (convexProcesses) => {
          status.convexReady = true;
          await logger.info("Convex is ready!");
          return convexProcesses;
        }
      );
      cleanupFunctions.push(async () => {
        const convexProcesses = await convexProcessesPromise;
        convexProcesses.backend.kill();
      });
      
      // Wait for Convex to be ready before proceeding
      await convexProcessesPromise;
    } catch (error) {
      await logger.error(`Failed to start Convex: ${error}`);
      console.error("Failed to start Convex:", error);
      process.exit(1);
    }

    // Deploy convex functions only on first install/upgrade
    if (didExtract) {
      try {
        await deployConvexFunctions(convexDir, process.env.CONVEX_PORT || "9777");
      } catch (error) {
        await logger.error(`Convex deployment failed: ${error}`);
        console.error("Convex deployment failed:", error);
        process.exit(1);
      }
    }

    // Check if static directory exists
    if (!existsSync(staticDir)) {
      console.error(`Static directory not found at: ${staticDir}`);
      console.error("This should have been extracted automatically.");
      console.error("Try deleting ~/.cmux and running the CLI again.");
      process.exit(1);
    }

    console.log(
      "\x1b[32m✓\x1b[0m Link: \x1b[36mhttp://localhost:" + port + "\x1b[0m\n"
    );

    let gitRepoInfo = null;
    if (repoPath) {
      const targetPath = repoPath === "." ? process.cwd() : repoPath;
      try {
        gitRepoInfo = getGitRepoInfo(targetPath);
        if (!gitRepoInfo.isGitRepo) {
          console.error(
            `\x1b[31m✗\x1b[0m Error: ${targetPath} is not a git repository`
          );
          process.exit(1);
        }
        console.log(
          `\x1b[32m✓\x1b[0m Git repository detected: ${gitRepoInfo.path}`
        );
        if (gitRepoInfo.remoteName) {
          console.log(`  Remote: ${gitRepoInfo.remoteName}`);
        } else if (gitRepoInfo.remoteUrl) {
          console.log(`  Remote URL: ${gitRepoInfo.remoteUrl}`);
          console.log(
            `  \x1b[33m⚠\x1b[0m  Could not extract repository name from URL`
          );
        }
        if (gitRepoInfo.currentBranch) {
          console.log(`  Branch: ${gitRepoInfo.currentBranch}`);
        }
      } catch (error) {
        console.error(
          `\x1b[31m✗\x1b[0m Error: ${error instanceof Error ? error.message : String(error)}`
        );
        process.exit(1);
      }
    }

    const serverPromise = startServer({
      port,
      publicPath: staticDir,
      defaultRepo: gitRepoInfo,
    }).then((server) => {
      status.serverReady = true;
      return server;
    });
    cleanupFunctions.push(async () => {
      const server = await serverPromise;
      await server.cleanup();
    });
  });

program
  .command("uninstall")
  .description("Remove cmux data and show uninstall instructions")
  .action(async () => {
    console.log("\n\x1b[33m🗑️  Uninstalling cmux...\x1b[0m\n");

    // Remove ~/.cmux directory
    if (existsSync(convexDir)) {
      try {
        console.log(`Removing data directory: ${convexDir}`);
        rmSync(convexDir, { recursive: true, force: true });
        console.log("\x1b[32m✓\x1b[0m Data directory removed successfully");
      } catch (error) {
        console.error(
          "\x1b[31m✗\x1b[0m Failed to remove data directory:",
          error
        );
      }
    } else {
      console.log("\x1b[33m!\x1b[0m Data directory not found, skipping...");
    }

    // Show uninstall instructions based on how it might have been installed
    console.log("\n\x1b[36mTo complete the uninstallation:\x1b[0m\n");

    console.log("If installed globally with npm:");
    console.log("  \x1b[90mnpm uninstall -g cmux\x1b[0m\n");

    console.log("If installed globally with yarn:");
    console.log("  \x1b[90myarn global remove cmux\x1b[0m\n");

    console.log("If installed globally with pnpm:");
    console.log("  \x1b[90mpnpm uninstall -g cmux\x1b[0m\n");

    console.log("If installed globally with bun:");
    console.log("  \x1b[90mbun uninstall -g cmux\x1b[0m\n");

    console.log("\x1b[32m✓\x1b[0m cmux data has been removed!");
    process.exit(0);
  });

program.parse();
