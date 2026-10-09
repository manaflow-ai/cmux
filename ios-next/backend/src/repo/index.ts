import { dbConfigured, type AppEnv } from "../env";
import { MemoryRepo } from "./memory";
import { PlanetScaleRepo } from "./planetscale";
import type { Repo } from "./types";

export type { Repo } from "./types";
export { MemoryRepo } from "./memory";

let memory: MemoryRepo | undefined;

/** Process-wide in-memory store used when `REPO_BACKEND=memory` (tests). */
export function sharedMemoryRepo(): MemoryRepo {
  memory ??= new MemoryRepo();
  return memory;
}

/** Returns null when no database is configured. */
export function repoFromEnv(env: AppEnv): Repo | null {
  if (!dbConfigured(env)) return null;
  if (env.REPO_BACKEND === "memory") return sharedMemoryRepo();
  return PlanetScaleRepo.fromEnv(env);
}
