import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "sqlite",
  schema: "./src/accountDrizzleSchema.ts",
  out: "./drizzle",
  strict: true,
  verbose: true,
});
