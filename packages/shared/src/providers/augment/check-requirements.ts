export async function checkAugmentRequirements(): Promise<string[]> {
  const missingRequirements: string[] = [];
  
  // Check for node/npm
  const { exec } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execAsync = promisify(exec);
  
  try {
    await execAsync("which node");
  } catch {
    missingRequirements.push("Node.js is not installed");
  }
  
  try {
    await execAsync("which npm");
  } catch {
    missingRequirements.push("npm is not installed");
  }
  
  // Check if auggie is installed globally
  try {
    await execAsync("npm list -g @augmentcode/auggie");
  } catch {
    missingRequirements.push("Augment CLI (auggie) is not installed. Run: npm install -g @augmentcode/auggie");
  }
  
  // Check for auth file
  const { readFile } = await import("node:fs/promises");
  const { homedir } = await import("node:os");
  
  try {
    await readFile(`${homedir()}/.augment/auth.json`, "utf-8");
  } catch {
    missingRequirements.push("Augment is not authenticated. Please log in to Augment locally first");
  }
  
  return missingRequirements;
}