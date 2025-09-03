import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";

// Lightweight stable hash for change detection (DJB2)
function hashStringDjb2(input: string): string {
  let hash = 5381;
  for (let i = 0; i < input.length; i++) {
    // hash * 33 + char
    hash = (hash << 5) + hash + input.charCodeAt(i);
    // Convert to 32-bit int
    hash |= 0;
  }
  // Return unsigned hex
  return (hash >>> 0).toString(16);
}

// Deeply sort object keys for deterministic stringification
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortKeys);
  }
  if (value && typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(obj).sort()) {
      sorted[key] = sortKeys(obj[key]);
    }
    return sorted;
  }
  return value;
}

function canonicalize(payload: {
  settings?: unknown;
  keybindings?: unknown;
  snippets?: unknown;
  extensions?: string[];
}): string {
  const normalized = sortKeys(payload);
  return JSON.stringify(normalized);
}

export const get = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const existing = await ctx.db
      .query("vscodeSettings")
      .withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId))
      .first();
    return existing ?? null;
  },
});

export const upsert = authMutation({
  args: {
    teamSlugOrId: v.string(),
    settings: v.optional(v.any()),
    keybindings: v.optional(v.any()),
    snippets: v.optional(v.any()),
    extensions: v.optional(v.array(v.string())),
    hash: v.optional(v.string()), // if omitted, computed server-side (non-crypto)
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const existing = await ctx.db
      .query("vscodeSettings")
      .withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId))
      .first();

    const canonical = canonicalize({
      settings: args.settings,
      keybindings: args.keybindings,
      snippets: args.snippets,
      extensions: args.extensions,
    });
    const newHash = args.hash ?? hashStringDjb2(canonical);
    const now = Date.now();

    if (existing && existing.hash === newHash) {
      return { updated: false, hash: existing.hash, updatedAt: existing.updatedAt };
    }

    if (existing) {
      await ctx.db.patch(existing._id, {
        settings: args.settings,
        keybindings: args.keybindings,
        snippets: args.snippets,
        extensions: args.extensions,
        hash: newHash,
        updatedAt: now,
      });
      return { updated: true, hash: newHash, updatedAt: now };
    }

    await ctx.db.insert("vscodeSettings", {
      userId,
      teamId,
      settings: args.settings,
      keybindings: args.keybindings,
      snippets: args.snippets,
      extensions: args.extensions,
      hash: newHash,
      createdAt: now,
      updatedAt: now,
    });
    return { updated: true, hash: newHash, updatedAt: now };
  },
});

