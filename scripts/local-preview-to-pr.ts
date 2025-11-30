#!/usr/bin/env bun
/**
 * Local Preview to PR Script
 *
 * Runs screenshots locally using Docker and posts the results to a GitHub PR
 * via the existing Convex preview screenshot flow.
 *
 * Usage:
 *   bun run scripts/local-preview-to-pr.ts --pr https://github.com/owner/repo/pull/123 --team <team-slug>
 *
 * Options:
 *   --pr <url>       Required. The GitHub PR URL to post screenshots to.
 *   --team <slug>    Required. The team slug or ID.
 *   --skip-capture   Skip screenshot capture and use existing screenshots in tmp/
 *   --dry-run        Don't upload to Convex or post to GitHub, just show what would happen
 *
 * Requirements:
 *   - CONVEX_URL environment variable (or uses default production URL)
 *   - STACK_* environment variables for authentication
 *   - Docker installed and running (unless --skip-capture)
 *   - ANTHROPIC_API_KEY in environment (for screenshot capture)
 */

import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import process from "node:process";
import { api } from "@cmux/convex/api";
import { StackAdminApp } from "@stackframe/js";
import { ConvexHttpClient } from "convex/browser";
import "dotenv/config";

const SCREENSHOT_JSON = "tmp/cmux-screenshots-latest.json";

interface ScreenshotManifest {
  hasUiChanges: boolean;
  images: Array<{
    path: string;
    description: string;
  }>;
}

interface ParsedPrUrl {
  owner: string;
  repo: string;
  number: number;
  repoFullName: string;
  prUrl: string;
}

interface Options {
  prUrl: string;
  teamSlugOrId: string;
  skipCapture: boolean;
  dryRun: boolean;
  createConfig: boolean;
}

// Default values for cmux team (has active manaflow-ai GitHub App connection)
const DEFAULT_TEAM_ID = "33e9f970-20c0-44ce-be20-6ef75c6b9b2b";
const DEFAULT_USER_ID = "c0aed31a-e354-4b01-92c4-853aa76ea80a";

function parseArgs(args: string[]): Options {
  let prUrl = "";
  let teamSlugOrId = DEFAULT_TEAM_ID;
  let skipCapture = false;
  let dryRun = false;
  let createConfig = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--pr") {
      prUrl = args[++i] ?? "";
    } else if (arg?.startsWith("--pr=")) {
      prUrl = arg.slice(5);
    } else if (arg === "--team") {
      teamSlugOrId = args[++i] ?? DEFAULT_TEAM_ID;
    } else if (arg?.startsWith("--team=")) {
      teamSlugOrId = arg.slice(7);
    } else if (arg === "--skip-capture") {
      skipCapture = true;
    } else if (arg === "--dry-run") {
      dryRun = true;
    } else if (arg === "--create-config") {
      createConfig = true;
    } else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      console.error(`Unknown argument: ${arg}`);
      printUsage();
      process.exit(1);
    }
  }

  if (!prUrl) {
    console.error("Error: --pr is required");
    printUsage();
    process.exit(1);
  }

  return { prUrl, teamSlugOrId, skipCapture, dryRun, createConfig };
}

function printUsage(): void {
  console.log(`
Usage: bun run scripts/local-preview-to-pr.ts --pr <PR_URL> [options]

Options:
  --pr <url>       Required. The GitHub PR URL to post screenshots to.
  --team <slug>    Optional. The team slug or ID (defaults to cmux team).
  --skip-capture   Skip screenshot capture and use existing screenshots in tmp/
  --dry-run        Don't upload to Convex or post to GitHub, just show what would happen
  --create-config  Create a preview config for the repo if it doesn't exist
  --help, -h       Show this help message

Environment Variables:
  CONVEX_URL                          Convex deployment URL (defaults to production)
  NEXT_PUBLIC_STACK_PROJECT_ID        Stack project ID
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY  Stack publishable key
  STACK_SECRET_SERVER_KEY             Stack secret server key
  STACK_SUPER_SECRET_ADMIN_KEY        Stack admin key
  CMUX_SCRIPT_USER_ID                 Stack user ID (defaults to cmux default user)
  ANTHROPIC_API_KEY                   Required for screenshot capture

Examples:
  bun run scripts/local-preview-to-pr.ts --pr https://github.com/manaflow-ai/cmux/pull/123
  bun run scripts/local-preview-to-pr.ts --pr https://github.com/manaflow-ai/cmux/pull/123 --skip-capture
  bun run scripts/local-preview-to-pr.ts --pr https://github.com/manaflow-ai/cmux/pull/123 --dry-run
`);
}

function parsePrUrl(url: string): ParsedPrUrl | null {
  const match = url.match(
    /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/
  );
  if (!match) {
    return null;
  }
  return {
    owner: match[1],
    repo: match[2],
    number: parseInt(match[3], 10),
    repoFullName: `${match[1]}/${match[2]}`,
    prUrl: url,
  };
}

async function getConvexClient(): Promise<ConvexHttpClient> {
  const convexUrl =
    process.env.CONVEX_URL ??
    process.env.NEXT_PUBLIC_CONVEX_URL ??
    "https://polite-canary-804.convex.cloud";

  // Initialize Stack admin app to get auth token
  const stackAdminApp = new StackAdminApp({
    tokenStore: "memory",
    projectId: process.env.NEXT_PUBLIC_STACK_PROJECT_ID,
    publishableClientKey: process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
    secretServerKey: process.env.STACK_SECRET_SERVER_KEY,
    superSecretAdminKey: process.env.STACK_SUPER_SECRET_ADMIN_KEY,
  });

  // Get current user from Stack - we need to get a user to create a session
  // For scripts, we typically use a service account or the admin's user ID
  const userId = process.env.CMUX_SCRIPT_USER_ID ?? DEFAULT_USER_ID;

  const user = await stackAdminApp.getUser(userId);
  if (!user) {
    throw new Error(`User not found: ${userId}`);
  }

  const session = await user.createSession({ expiresInMillis: 10 * 60 * 1000 }); // 10 minutes
  const tokens = await session.getTokens();
  const token = tokens.accessToken;

  if (!token) {
    throw new Error("Failed to get access token from Stack");
  }

  const client = new ConvexHttpClient(convexUrl);
  client.setAuth(token);

  return client;
}

async function runDockerScreenshot(prUrl: string): Promise<boolean> {
  console.log("\n📸 Running screenshot capture...\n");

  return new Promise((resolve) => {
    const scriptPath = path.join(
      process.cwd(),
      "scripts/docker-trigger-screenshot.sh"
    );

    const child = spawn(
      "bash",
      [scriptPath, "--pr", prUrl, "--exec", "sleep 1"],
      {
        stdio: "inherit",
        cwd: process.cwd(),
      }
    );

    child.on("close", (code) => {
      if (code === 0) {
        console.log("\n✅ Screenshot capture completed\n");
        resolve(true);
      } else {
        console.error(`\n❌ Screenshot capture failed with code ${code}\n`);
        resolve(false);
      }
    });

    child.on("error", (err) => {
      console.error("Failed to run screenshot script:", err);
      resolve(false);
    });
  });
}

function loadScreenshotManifest(): ScreenshotManifest | null {
  const jsonPath = path.join(process.cwd(), SCREENSHOT_JSON);
  if (!fs.existsSync(jsonPath)) {
    console.error(`Screenshot manifest not found at ${jsonPath}`);
    return null;
  }

  try {
    const content = fs.readFileSync(jsonPath, "utf-8");
    return JSON.parse(content) as ScreenshotManifest;
  } catch (err) {
    console.error("Failed to parse screenshot manifest:", err);
    return null;
  }
}

function getCommitSha(): string {
  const result = spawnSync("git", ["rev-parse", "HEAD"], {
    encoding: "utf-8",
    cwd: process.cwd(),
  });
  if (result.status === 0) {
    return result.stdout.trim();
  }
  return `local-${Date.now()}`;
}

function getHeadRef(): string | undefined {
  const result = spawnSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
    encoding: "utf-8",
    cwd: process.cwd(),
  });
  if (result.status === 0) {
    const ref = result.stdout.trim();
    return ref !== "HEAD" ? ref : undefined;
  }
  return undefined;
}

async function uploadImageToConvex(
  client: ConvexHttpClient,
  imagePath: string,
  teamSlugOrId: string
): Promise<{ storageId: string; mimeType: string; fileName: string }> {
  // Get upload URL
  const uploadUrl = await client.mutation(api.storage.generateUploadUrl, {
    teamSlugOrId,
  });

  // Read the file
  const fileContent = fs.readFileSync(imagePath);
  const fileName = path.basename(imagePath);
  const ext = path.extname(imagePath).toLowerCase();

  const mimeTypes: Record<string, string> = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
  };
  const mimeType = mimeTypes[ext] ?? "image/png";

  // Upload the file
  const uploadResponse = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      "Content-Type": mimeType,
    },
    body: fileContent,
  });

  if (!uploadResponse.ok) {
    throw new Error(
      `Failed to upload image: ${uploadResponse.status} ${uploadResponse.statusText}`
    );
  }

  const result = (await uploadResponse.json()) as { storageId: string };

  return {
    storageId: result.storageId,
    mimeType,
    fileName,
  };
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));

  const parsedPr = parsePrUrl(options.prUrl);
  if (!parsedPr) {
    console.error(
      "Invalid PR URL format. Expected: https://github.com/owner/repo/pull/123"
    );
    process.exit(1);
  }

  console.log(`\n🎯 Target PR: ${parsedPr.repoFullName}#${parsedPr.number}\n`);
  console.log(`📦 Team: ${options.teamSlugOrId}\n`);

  // Step 1: Run screenshot capture (unless skipped)
  if (!options.skipCapture) {
    const success = await runDockerScreenshot(options.prUrl);
    if (!success) {
      console.error(
        "Screenshot capture failed. Use --skip-capture to use existing screenshots."
      );
      process.exit(1);
    }
  } else {
    console.log(
      "⏭️  Skipping screenshot capture (using existing screenshots)\n"
    );
  }

  // Step 2: Load screenshot manifest
  const manifest = loadScreenshotManifest();
  if (!manifest) {
    console.error(
      "No screenshot manifest found. Run without --skip-capture first."
    );
    process.exit(1);
  }

  console.log(`📋 Found ${manifest.images.length} screenshot(s)\n`);

  if (options.dryRun) {
    console.log("🔍 [DRY RUN] Would upload the following screenshots:");
    for (const img of manifest.images) {
      console.log(`   - ${img.path}`);
    }
    console.log(
      "\n🔍 [DRY RUN] Would create preview run and post GitHub comment"
    );
    console.log("\n✅ Dry run complete\n");
    return;
  }

  // Step 3: Get Convex client with auth
  console.log("🔐 Authenticating with Convex...\n");
  const client = await getConvexClient();

  // Step 4: Get commit info
  const commitSha = getCommitSha();
  const headRef = getHeadRef();
  console.log(`📝 Commit: ${commitSha.slice(0, 7)}\n`);

  // Step 5: Ensure preview config exists (if --create-config flag is set)
  if (options.createConfig) {
    console.log("📋 Ensuring preview config exists...\n");
    try {
      await client.mutation(api.previewConfigs.upsert, {
        teamSlugOrId: options.teamSlugOrId,
        repoFullName: parsedPr.repoFullName,
        status: "active",
      });
      console.log(`   ✅ Preview config ready for ${parsedPr.repoFullName}\n`);
    } catch (err) {
      console.error(`   ❌ Failed to create preview config:`, err);
      process.exit(1);
    }
  }

  // Step 6: Create manual preview run
  console.log("📤 Creating preview run...\n");
  const { previewRunId, reused } = await client.mutation(
    api.previewRuns.createManual,
    {
      teamSlugOrId: options.teamSlugOrId,
      repoFullName: parsedPr.repoFullName,
      prNumber: parsedPr.number,
      prUrl: parsedPr.prUrl,
      headSha: commitSha,
      headRef,
    }
  );

  if (reused) {
    console.log(`   ♻️  Reusing existing preview run: ${previewRunId}\n`);
  } else {
    console.log(`   ✅ Created preview run: ${previewRunId}\n`);
  }

  // Step 6: Upload screenshots to Convex storage
  console.log("📤 Uploading screenshots to Convex...\n");
  const uploadedImages: Array<{
    storageId: string;
    mimeType: string;
    fileName: string;
    commitSha: string;
  }> = [];

  for (const image of manifest.images) {
    console.log(`   Uploading ${path.basename(image.path)}...`);
    try {
      const uploaded = await uploadImageToConvex(
        client,
        image.path,
        options.teamSlugOrId
      );
      uploadedImages.push({
        ...uploaded,
        commitSha,
      });
      console.log(`   ✅ Uploaded: ${uploaded.storageId}`);
    } catch (err) {
      console.error(`   ❌ Failed to upload ${image.path}:`, err);
    }
  }

  if (uploadedImages.length === 0) {
    console.error("\n❌ No images were uploaded successfully\n");
    process.exit(1);
  }

  // Step 7: Create screenshot set and trigger GitHub comment
  console.log("\n📤 Creating screenshot set and posting GitHub comment...\n");

  const result = await client.action(api.previewScreenshots.uploadAndComment, {
    previewRunId,
    status: "completed",
    commitSha,
    images: uploadedImages,
  });

  if (result.ok) {
    console.log(`   ✅ Screenshot set created: ${result.screenshotSetId}`);
    if (result.githubCommentUrl) {
      console.log(`   🔗 GitHub comment: ${result.githubCommentUrl}`);
    } else {
      console.log(
        `   ⚠️  GitHub comment was not posted (check if repo has GitHub App installed)`
      );
    }
  } else {
    console.error("   ❌ Failed to create screenshot set");
  }

  console.log("\n🎉 Done!\n");
}

main().catch((err) => {
  console.error("Unexpected error:", err);
  process.exit(1);
});
