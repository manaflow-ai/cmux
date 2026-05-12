import { existsSync, readFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { createFallbackState, parseHomeState, type HomeState } from "./state";

export interface LoadStateOptions {
  data?: string;
  cwd?: string;
}

export function loadHomeState(options: LoadStateOptions = {}): HomeState {
  const cwd = options.cwd ?? process.cwd();
  if (options.data) {
    return parseHomeState(readJsonInput(options.data, cwd));
  }

  const shared = readSharedStateIfPresent(cwd);
  if (shared !== undefined) {
    return parseHomeState(shared);
  }

  return createFallbackState();
}

function readJsonInput(input: string, cwd: string): unknown {
  const trimmed = input.trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    return JSON.parse(trimmed);
  }

  const filePath = isAbsolute(trimmed) ? trimmed : resolve(cwd, trimmed);
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function readSharedStateIfPresent(cwd: string): unknown {
  for (const candidate of sharedStateCandidates(cwd)) {
    if (!existsSync(candidate)) {
      continue;
    }
    return JSON.parse(readFileSync(candidate, "utf8"));
  }
  return undefined;
}

function sharedStateCandidates(cwd: string): string[] {
  return [
    join(cwd, "state.json"),
    join(cwd, "example-state.json"),
    join(cwd, "..", "state.json"),
    join(cwd, "..", "example-state.json"),
    join(cwd, "..", "examples", "state.sample.json"),
    join(cwd, "..", "examples", "home-state.json"),
    join(cwd, "..", "examples", "example-state.json"),
    join(cwd, "..", "shared", "state.json"),
    join(cwd, "..", "shared", "example-state.json"),
  ];
}
