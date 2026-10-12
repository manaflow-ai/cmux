// Applies schema.sql through the PlanetScale fetch driver.
// Env: DB_HOST, DB_USERNAME, DB_PASSWORD.
import { connect } from "@planetscale/database";
import { readFileSync } from "node:fs";
const conn = connect({ host: process.env.DB_HOST, username: process.env.DB_USERNAME, password: process.env.DB_PASSWORD });
const sql = readFileSync(new URL("../schema.sql", import.meta.url), "utf8").replace(/^--.*$/gm, "");
for (const stmt of sql.split(";").map((s) => s.trim()).filter(Boolean)) {
  await conn.execute(stmt);
  console.log("ok:", stmt.split("\n")[0]);
}
const t = await conn.execute("SHOW TABLES");
console.log("tables:", t.rows.map((r) => Object.values(r)[0]).join(", "));
