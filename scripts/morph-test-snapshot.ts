#!/usr/bin/env tsx
import { MorphCloudClient } from "morphcloud";
import path from "path";
import dotenv from "dotenv";
import { fileURLToPath } from "url";

// Load environment variables
const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, ".env") });

async function main() {
  try {
    const client = new MorphCloudClient();
    
    // Replace with your actual snapshot ID
    const snapshotId = "snapshot_c16u3ggu"; // From the morph-final.ts output
    
    console.log(`Starting instance from snapshot ${snapshotId}...`);
    const instance = await client.instances.start({
      snapshotId: snapshotId,
      ttlSeconds: 60 * 30,
      ttlAction: "pause",
    });

    await instance.waitUntilReady();

    console.log("Instance is ready!");
    console.log(`Instance ID: ${instance.id}`);

    // Test the setup
    console.log("\n=== Testing Docker ===");
    const dockerTest = await instance.exec("docker --version");
    console.log(dockerTest.stdout);

    console.log("\n=== Testing Node.js ===");
    const nodeTest = await instance.exec("node --version");
    console.log(nodeTest.stdout);

    console.log("\n=== Testing Bun ===");
    const bunTest = await instance.exec("/root/.bun/bin/bun --version");
    console.log(bunTest.stdout);

    console.log("\n=== Running test script ===");
    const testScript = await instance.exec("cd /worker && node test.js");
    console.log(testScript.stdout);

    console.log("\n✅ All tests passed!");

    // Keep instance running for manual testing if needed
    console.log("\nInstance is running. You can connect via:");
    console.log(`- SSH: Use MorphCloud CLI or dashboard`);
    console.log(`- Instance ID: ${instance.id}`);
    
    console.log("\nPress Ctrl+C to stop the instance...");
    
    // Handle graceful shutdown
    process.on('SIGINT', async () => {
      console.log("\nStopping instance...");
      await instance.stop();
      process.exit(0);
    });

    // Keep the script running
    await new Promise(() => {});

  } catch (error) {
    console.error("Error:", error);
    process.exit(1);
  }
}

main();
