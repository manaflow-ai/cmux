import { defineConfig } from "drizzle-kit";

function defaultDatabaseURL(): string {
  const rawPort = process.env.CMUX_PORT ?? process.env.PORT ?? "3777";
  const cmuxPort = /^\d+$/.test(rawPort) ? Number(rawPort) : 3777;
  const offset = Number(process.env.CMUX_DB_PORT_OFFSET ?? "10000");
  const dbPort = process.env.CMUX_DB_PORT ?? String(cmuxPort + offset);
  const user = process.env.CMUX_DB_USER ?? "cmux";
  const password = process.env.CMUX_DB_PASSWORD ?? "cmux";
  const database = process.env.CMUX_DB_NAME ?? "cmux";
  return `postgres://${user}:${password}@localhost:${dbPort}/${database}`;
}

export default defineConfig({
  schema: "./db/schema.ts",
  out: "./db/migrations",
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL ?? defaultDatabaseURL(),
  },
  strict: true,
  verbose: true,
});
