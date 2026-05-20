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
  const message = error instanceof Error ? error.message : String(error);
  console.error(`aws-rds-iam migration failed: ${message}`);
  process.exit(1);
});
