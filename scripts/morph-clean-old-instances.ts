#!/usr/bin/env bun

import { Instance, MorphCloudClient } from "morphcloud";
import { createInterface } from "node:readline/promises";
import process, { stdin as input, stdout as output } from "node:process";

const MILLISECONDS_PER_DAY = 24 * 60 * 60 * 1000;
const DEFAULT_DAYS = 3;

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

function parseDays(rawArgs: string[]): number {
  let days = DEFAULT_DAYS;
  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index];
    if (arg.startsWith("--days=")) {
      days = parseDaysValue(arg.slice("--days=".length));
    } else if (arg === "--days" || arg === "-d") {
      const next = rawArgs[index + 1];
      if (!next) {
        console.error("Expected value after --days flag.");
        process.exit(1);
      }
      days = parseDaysValue(next);
      index += 1;
    } else if (arg.startsWith("N=")) {
      days = parseDaysValue(arg.slice("N=".length));
    }
  }
  return days;
}

function parseDaysValue(value: string): number {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    console.error(`Invalid days value: ${value}`);
    process.exit(1);
  }
  return parsed;
}

function buildStatusCounts(instanceList: Instance[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const instance of instanceList) {
    counts.set(instance.status, (counts.get(instance.status) ?? 0) + 1);
  }
  return counts;
}

function logStatusTotals(counts: Map<string, number>, heading = "Instance state totals:"): void {
  console.log(heading);
  for (const [status, count] of [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
    console.log(`- ${status.toLowerCase()}: ${count}`);
  }
}

function ensureStatusKeys(counts: Map<string, number>): void {
  for (const key of ["paused", "ready"]) {
    if (!counts.has(key)) {
      counts.set(key, 0);
    }
  }
}

function printInstanceSummaries(
  totalCounts: Map<string, number>,
  oldCounts: Map<string, number>,
  oldCount: number,
  days: number,
  {
    totalHeading = "Instance state totals:",
    oldHeadingSuffix = "",
  }: {
    totalHeading?: string;
    oldHeadingSuffix?: string;
  } = {}
): void {
  logStatusTotals(totalCounts, totalHeading);
  console.log(
    `Found ${oldCount} instance${oldCount === 1 ? "" : "s"} older than ${days} day${days === 1 ? "" : "s"}.`
  );
  ensureStatusKeys(oldCounts);
  logStatusTotals(
    oldCounts,
    `Instances older than ${days} day${days === 1 ? "" : "s"} totals${oldHeadingSuffix}:`
  );
}

const client = new MorphCloudClient();
const instances = await client.instances.list();

if (instances.length === 0) {
  console.log("No instances found.");
  process.exit(0);
}

const days = parseDays(process.argv.slice(2));
const thresholdMs = days * MILLISECONDS_PER_DAY;

const now = Date.now();
const oldInstances = instances.filter(
  (instance) => now - instance.created * 1000 > thresholdMs
);
const sortedOldInstances = [...oldInstances].sort((a, b) => a.created - b.created);
const statusCounts = buildStatusCounts(instances);
const oldStatusCounts = buildStatusCounts(oldInstances);

console.log("\nInstances eligible for deletion:");

if (sortedOldInstances.length === 0) {
  printInstanceSummaries(statusCounts, oldStatusCounts, 0, days);
  console.log("No instances matched the deletion criteria.");
  process.exit(0);
}

console.log("");
for (const instance of sortedOldInstances) {
  const createdAt = new Date(instance.created * 1000).toISOString();
  console.log(
    `- ${instance.id} (${instance.status.toLowerCase()}) created ${createdAt} (${formatRelativeTime(instance)})`
  );
}

printInstanceSummaries(statusCounts, oldStatusCounts, sortedOldInstances.length, days);

const rl = createInterface({ input, output });
const answer = await rl.question(
  "\nPress Enter to delete these instances, or type anything else to cancel: "
);
await rl.close();

if (answer.trim() !== "") {
  console.log("Did not delete any instances.");
  process.exit(0);
}

let failures = 0;
for (const instance of sortedOldInstances) {
  console.log(`Deleting ${instance.id}...`);
  try {
    await instance.stop();
    console.log(`Deleted ${instance.id}.`);
  } catch (error) {
    failures += 1;
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Failed to delete ${instance.id}: ${message}`);
  }
}

const refreshedInstances = await client.instances.list();
console.log("");
const refreshedOldInstances = refreshedInstances.filter(
  (instance) => Date.now() - instance.created * 1000 > thresholdMs
);
const refreshedOldStatusCounts = buildStatusCounts(refreshedOldInstances);
printInstanceSummaries(
  buildStatusCounts(refreshedInstances),
  refreshedOldStatusCounts,
  refreshedOldInstances.length,
  days,
  { totalHeading: "Instance state totals (after delete):", oldHeadingSuffix: " (after delete)" }
);

if (failures > 0) {
  process.exitCode = 1;
}
