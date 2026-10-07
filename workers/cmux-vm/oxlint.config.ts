// gdp-ts preset in strict mode: proofs are minted only in src/proofs/, provers
// are never exported, and no `as` or `any` outside src/proofs/ and
// src/lib/ids.ts can forge one.
import gdp from "@gdp-ts/core/lint/oxlint";

export default gdp({ strict: true, proofs: ["src/proofs/**"], allowAssertions: ["src/lib/ids.ts"] });
