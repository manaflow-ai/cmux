import { describe, expect, it } from "vitest"
import { call, PROD_PROJECT, token } from "./helpers.ts"

// Full verify D1 (2026-10-19): the phone created teams with Stack's client API, which both Stack
// projects refuse (client_team_creation_enabled is false), so no team ever appeared. The Worker
// creates the team with the project's server key and makes the caller its creator and member.
describe("POST /v1/teams", () => {
  it("creates a team for the caller and returns its id and name", async () => {
    const r = await call("POST", "/v1/teams", await token("alice"), { name: "  fv team  " })
    expect(r.status).toBe(200)
    expect(r.json.team).toEqual({ id: expect.stringMatching(/^team-/), name: "fv team" })
  })

  it("needs a name of at most 64 characters", async () => {
    const tok = await token("alice")
    expect((await call("POST", "/v1/teams", tok, {})).status).toBe(400)
    expect((await call("POST", "/v1/teams", tok, { name: "   " })).status).toBe(400)
    expect((await call("POST", "/v1/teams", tok, { name: "x".repeat(65) })).status).toBe(400)
  })

  it("says so when this Worker cannot create teams for the caller's project", async () => {
    const r = await call("POST", "/v1/teams", await token("pat", { project: PROD_PROJECT }), { name: "Prod team" })
    expect(r.status).toBe(503)
    expect(r.json.error.code).toBe("team_creation_unavailable")
  })

  it("needs a signed-in caller", async () => {
    expect((await call("POST", "/v1/teams", undefined, { name: "x" })).status).toBe(401)
  })
})
