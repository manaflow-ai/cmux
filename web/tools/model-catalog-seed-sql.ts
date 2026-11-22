// Prints the catalog_overrides seed (overrides.ts as rows) as SQL, for the
// model catalog migration. tests/model-catalog-db.test.ts checks that the
// migration holds exactly these statements.
//   bun tools/model-catalog-seed-sql.ts

import { seedRows } from "../services/model-catalog/overrideRows";

const quote = (text: string) => `'${text.replaceAll("'", "''")}'`;

export function seedSql(): string {
  const values = seedRows().map((row) =>
    `  (${quote(row.kind)}, ${quote(row.harnessId)}, ${row.modelId === null ? "NULL" : quote(row.modelId)}, ${quote(JSON.stringify(row.value))}::jsonb, 'seed')`,
  );
  return `INSERT INTO "catalog_overrides" ("kind", "harness_id", "model_id", "value", "author") VALUES\n${values.join(",\n")}\nON CONFLICT ON CONSTRAINT "catalog_overrides_target_unique" DO NOTHING;\n`;
}

if (process.argv[1]?.endsWith("model-catalog-seed-sql.ts")) process.stdout.write(seedSql());
