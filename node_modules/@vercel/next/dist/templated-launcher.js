"use strict";
process.chdir(__dirname);
if (!process.env.NODE_ENV) {
  const region = process.env.VERCEL_REGION || process.env.NOW_REGION;
  process.env.NODE_ENV = region === "dev1" ? "development" : "production";
}
const page = require(__LAUNCHER_PAGE_PATH__);
module.exports = page.render || page.default || page;
