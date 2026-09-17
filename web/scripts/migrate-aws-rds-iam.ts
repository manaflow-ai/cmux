import { migrate } from "drizzle-orm/node-postgres/migrator";
import { drizzle } from "drizzle-orm/node-postgres";
import { cloudDbConfig } from "../db/config";
import { createAwsRdsIamPool } from "../db/client";
import * as schema from "../db/schema";

async function main() {
  const config = cloudDbConfig();
  if (config.driver !== "aws-rds-iam") {
    throw new Error("CMUX_DB_DRIVER=aws-rds-iam is required for this migration command");
  }

  const pool = createAwsRdsIamPool(config);
  try {
    const db = drizzle({ client: pool, schema });
    await migrate(db, { migrationsFolder: "db/migrations" });
  } finally {
    await pool.end();
  }
}

main().catch((error) => {
  const messages: string[] = [];
  let current: unknown = error;
  for (let depth = 0; depth < 4 && current; depth++) {
    messages.push(current instanceof Error ? current.message : String(current));
    current = typeof current === "object" && current !== null && "cause" in current
      ? current.cause
      : undefined;
  }
  const message = messages.join(": ");
  console.error(`aws-rds-iam migration failed: ${message}`);
  process.exit(1);
});
