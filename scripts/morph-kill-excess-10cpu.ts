#!/usr/bin/env bun

import { Instance, InstanceStatus, MorphCloudClient } from "morphcloud";
import { createInterface } from "node:readline/promises";
import process, { stdin as input, stdout as output } from "node:process";

const TARGET_VCPUS = 10;
const DEFAULT_KEEP_COUNT = 3;

function parseKeepCount(rawArgs: string[]): number {
  let keepCount = DEFAULT_KEEP_COUNT;
  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index];
    if (arg.startsWith("--keep=")) {
      keepCount = parseKeepCountValue(arg.slice("--keep=".length));
    } else if (arg === "--keep" || arg === "-k") {
      const next = rawArgs[index + 1];
      if (!next) {
        console.error("Expected value after --keep flag.");
        process.exit(1);
      }
      keepCount = parseKeepCountValue(next);
      index += 1;
    }
  }
  return keepCount;
}

function parseKeepCountValue(value: string): number {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    console.error(`Invalid keep value: ${value}`);
    process.exit(1);
  }
  return parsed;
}

function formatRelativeTime(instance: Instance): string {
  const diffMs = Date.now() - instance.created * 1000;
  const diffSeconds = Math.max(Math.floor(diffMs / 1000), 0);
  if (diffSeconds < 60) {
    return `${diffSeconds}s ago`;
  }
  const diffMinutes = Math.floor(diffSeconds / 60);
  if (diffMinutes < 60) {
    return `${diffMinutes}m ago`;
  }
  const diffHours = Math.floor(diffMinutes / 60);
  if (diffHours < 24) {
    return `${diffHours}h ago`;
  }
  const diffDays = Math.floor(diffHours / 24);
  if (diffDays < 30) {
    return `${diffDays}d ago`;
  }
  const diffMonths = Math.floor(diffDays / 30);
  if (diffMonths < 12) {
    return `${diffMonths}mo ago`;
  }
  const diffYears = Math.floor(diffDays / 365);
  return `${diffYears}y ago`;
}

function formatInstanceSummary(instance: Instance): string {
  const metadataName = instance.metadata?.name;
  const nameSegment = metadataName ? ` ${metadataName}` : "";
  const createdAt = new Date(instance.created * 1000).toISOString();
  return `${instance.id}${nameSegment} | ${instance.status.toLowerCase()} | ${createdAt} (${formatRelativeTime(instance)})`;
}

const keepCount = parseKeepCount(process.argv.slice(2));

const client = new MorphCloudClient();
const instances = await client.instances.list();

const matchingInstances = instances.filter(
  (instance) => instance.spec.vcpus === TARGET_VCPUS && instance.status === InstanceStatus.READY
);

if (matchingInstances.length === 0) {
  console.log(`No instances found with ${TARGET_VCPUS} vCPUs.`);
  process.exit(0);
}

const sorted = [...matchingInstances].sort((a, b) => b.created - a.created);
const keep = sorted.slice(0, keepCount);
const toDelete = sorted.slice(keepCount);
const actualKeepCount = keep.length;

console.log(
  `Found ${sorted.length} instance${sorted.length === 1 ? "" : "s"} with ${TARGET_VCPUS} vCPUs.`
);
console.log(
  `Keeping ${actualKeepCount} instance${actualKeepCount === 1 ? "" : "s"} with the most recent creation time.`
);

if (keep.length > 0) {
  console.log("\nInstances to keep:");
  for (const instance of keep) {
    console.log(`- ${formatInstanceSummary(instance)}`);
  }
}

if (toDelete.length === 0) {
  console.log("\nNo instances to delete.");
  process.exit(0);
}

console.log("\nInstances to delete:");
for (const instance of toDelete) {
  console.log(`- ${formatInstanceSummary(instance)}`);
}

const rl = createInterface({ input, output });
const answer = await rl.question(
  "\nPress Enter to delete the listed instances, or type anything else to cancel: "
);
await rl.close();

if (answer.trim() !== "") {
  console.log("Aborted. Did not delete any instances.");
  process.exit(0);
}

let failures = 0;
await Promise.all(
  toDelete.map(async (instance) => {
    console.log(`Deleting ${instance.id}...`);
    try {
      await instance.stop();
      console.log(`Deleted ${instance.id}.`);
    } catch (error) {
      failures += 1;
      const message = error instanceof Error ? error.message : String(error);
      console.error(`Failed to delete ${instance.id}: ${message}`);
    }
  })
);

if (failures > 0) {
  console.error(`Finished with ${failures} failure${failures === 1 ? "" : "s"}.`);
  process.exit(1);
}

console.log("Deletion complete.");
