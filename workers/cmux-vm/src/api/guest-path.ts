/**
 * The guest path rule every file route shares (read, write, list, stat, exists,
 * mkdir, remove, uploads). Its own module so the endpoint groups in src/api/
 * can use it without importing src/api.ts, which composes them.
 */
import { Schema } from "effect";

/** An absolute guest path: starts with `/`, no `..` segment, no NUL, at most 4096 characters. */
export const GuestPath = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(4096),
  Schema.filter((path) => path.startsWith("/") && !path.includes("\u0000") && !path.split("/").includes(".."), {
    message: () => "path must be absolute, without '..' segments or NUL characters",
  }),
).annotations({ identifier: "GuestPath", description: "Absolute path inside the VM, without '..' segments." });
