#!/usr/bin/env bun

import { z } from "zod";
import {
  applyIdeDepsPins,
  readIdeDeps,
  writeIdeDeps,
  type IdeDeps,
} from "./lib/ideDeps";

const npmResponseSchema = z.object({
  "dist-tags": z.object({
    latest: z.string().min(1),
  }),
});

async function fetchLatestNpmVersion(packageName: string): Promise<string> {
  const url = `https://registry.npmjs.org/${encodeURIComponent(packageName)}`;
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(
      `Failed to fetch npm info for ${packageName}: ${res.status}`,
    );
  }
  const data = npmResponseSchema.parse(await res.json());
  return data["dist-tags"].latest;
}

const marketplaceResponseSchema = z.object({
  results: z.array(
    z.object({
      extensions: z.array(
        z.object({
          versions: z.array(
            z.object({
              version: z.string().min(1),
            }),
          ),
        }),
      ),
    }),
  ),
});

const marketplaceFlags = 0x1 | 0x2 | 0x80 | 0x100;

async function fetchLatestExtensionVersion(
  publisher: string,
  name: string,
): Promise<string> {
  const body = {
    filters: [
      {
        criteria: [
          {
            filterType: 7,
            value: `${publisher}.${name}`,
          },
        ],
      },
    ],
    flags: marketplaceFlags,
  };

  const res = await fetch(
    "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json;api-version=3.0-preview.1",
      },
      body: JSON.stringify(body),
    },
  );

  if (!res.ok) {
    throw new Error(
      `Failed to fetch marketplace info for ${publisher}.${name}: ${res.status}`,
    );
  }

  const data = marketplaceResponseSchema.parse(await res.json());
  const version =
    data.results[0]?.extensions[0]?.versions[0]?.version ?? null;
  if (!version) {
    throw new Error(
      `No versions returned for marketplace extension ${publisher}.${name}`,
    );
  }
  return version;
}

async function bumpPackages(deps: IdeDeps): Promise<void> {
  const packageNames = Object.keys(deps.packages);
  const latestEntries = await Promise.all(
    packageNames.map(async (name) => {
      const version = await fetchLatestNpmVersion(name);
      return { name, version };
    }),
  );

  for (const { name, version } of latestEntries) {
    deps.packages[name] = version;
  }
}

async function bumpExtensions(deps: IdeDeps): Promise<void> {
  const latestVersions = await Promise.all(
    deps.extensions.map(async (ext) => {
      const version = await fetchLatestExtensionVersion(
        ext.publisher,
        ext.name,
      );
      return version;
    }),
  );

  if (latestVersions.length !== deps.extensions.length) {
    throw new Error(
      `Marketplace version count mismatch: expected ${deps.extensions.length}, got ${latestVersions.length}`,
    );
  }

  for (let i = 0; i < deps.extensions.length; i += 1) {
    const ext = deps.extensions[i];
    const latestVersion = latestVersions[i];
    if (!latestVersion) {
      throw new Error(
        `Missing latest version for extension ${ext.publisher}.${ext.name}`,
      );
    }
    ext.version = latestVersion;
  }
}

async function main(): Promise<void> {
  const repoRoot = process.cwd();
  const deps = await readIdeDeps(repoRoot);
  const originalDeps: IdeDeps = structuredClone(deps);

  await Promise.all([bumpPackages(deps), bumpExtensions(deps)]);

  const originalString = JSON.stringify(originalDeps);
  const updatedString = JSON.stringify(deps);
  const depsChanged = originalString !== updatedString;

  if (depsChanged) {
    await writeIdeDeps(repoRoot, deps);
    console.log("Updated configs/ide-deps.json");
  } else {
    console.log("configs/ide-deps.json already up to date.");
  }

  const { dockerfileChanged, snapshotChanged } = await applyIdeDepsPins(
    repoRoot,
    deps,
  );

  if (dockerfileChanged || snapshotChanged) {
    console.log(
      `Synced pins: Dockerfile=${dockerfileChanged}, snapshot=${snapshotChanged}`,
    );
  } else if (depsChanged) {
    console.log("Dockerfile and snapshot already in sync.");
  }
}

main().catch((error) => {
  console.error("bump-ide-deps failed:", error);
  process.exit(1);
});
