#!/usr/bin/env bun

import { Instance, MorphCloudClient } from "morphcloud";
import { createInterface } from "node:readline/promises";
import process, { stdin as input, stdout as output } from "node:process";

const HOURS_THRESHOLD: number = 2;
const MILLISECONDS_PER_HOUR = 60 * 60 * 1000;

function formatRelativeTime(instance: Instance): string {
  const diffMs = Date.now() - instance.created * 1000;
  const diffSeconds = Math.floor(diffMs / 1000);
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

function formatHourLabel(hours: number): string {
  return `${hours} hour${hours === 1 ? "" : "s"}`;
}

const client = new MorphCloudClient();
const instances = await client.instances.list();

if (instances.length === 0) {
  console.log("No instances found.");
  process.exit(0);
}

const now = Date.now();
const thresholdMs = HOURS_THRESHOLD * MILLISECONDS_PER_HOUR;
const staleActiveInstances = instances
  .filter((instance) => instance.status === "ready")
  .filter((instance) => now - instance.created * 1000 > thresholdMs)
  .sort((a, b) => a.created - b.created);

if (staleActiveInstances.length === 0) {
  console.log(`No active instances older than ${formatHourLabel(HOURS_THRESHOLD)}.`);
  process.exit(0);
}

console.log(
  `Found ${staleActiveInstances.length} active instance${staleActiveInstances.length === 1 ? "" : "s"} older than ${formatHourLabel(HOURS_THRESHOLD)}:\n`
);

for (const instance of staleActiveInstances) {
  const createdAt = new Date(instance.created * 1000).toISOString();
  console.log(
    `- ${instance.id} (${instance.status}) created ${createdAt} (${formatRelativeTime(instance)})`
  );
}

const rl = createInterface({ input, output });
const answer = await rl.question(
  "\nPress Enter to pause these instances, or type anything else to cancel: "
);
await rl.close();

if (answer.trim() !== "") {
  console.log("Did not pause any instances.");
  process.exit(0);
}

let failures = 0;
for (const instance of staleActiveInstances) {
  console.log(`Pausing ${instance.id}...`);
  try {
    await instance.pause();
    console.log(`Paused ${instance.id}. Current status: ${instance.status}.`);
  } catch (error) {
    failures += 1;
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Failed to pause ${instance.id}: ${message}`);
  }
}

if (failures === 0) {
  console.log("\nFinished pausing all targeted instances.");
} else {
  console.log(`\nFinished with ${failures} failure${failures === 1 ? "" : "s"}.`);
  process.exitCode = 1;
}
