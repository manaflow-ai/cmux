import { defineConfig } from "drizzle-kit";

/** Drizzle Kit source for the Durable Object SQLite schema. Runtime uses the immutable manifest. */
export default defineConfig({
  schema: "./src/storage/schema.ts",
  out: "./drizzle",
  dialect: "sqlite",
  strict: true,
  verbose: true,
});
