// Run 46175024290, agent daemon restart: the felt chat answered "Not logged in" after the kill, and the journal read
// from the kill could not say whether that chat had been put to sleep before it (its sent login is memory only).
import { describe, expect, it } from "bun:test"
import { sessionLife, sessionLifeCommand } from "./cloud-chaos.ts"

const kill = Date.parse("2026-11-28T18:40:00Z")

describe("sessionLife", () => {
  it("a chat whose newest line before the kill is a sleep was asleep at it", () => {
    const out = [
      "@@now 0",
      "2026-11-28T18:30:00.000Z  INFO acpmux::hub::spawn: agent launches on the owner's credential session=felt names=[\"CLAUDE_CODE_OAUTH_TOKEN\"]",
      "2026-11-28T18:30:00.000Z  INFO acpmux::hub::spawn: agent launches on the owner's credential session=count names=[\"CLAUDE_CODE_OAUTH_TOKEN\"]",
      "2026-11-28T18:35:00.000Z  INFO acpmux::hub::idle: hibernated: no turn session=felt cause=\"host-level\"",
      "2026-11-28T18:40:05.000Z  INFO acpmux::hub::credentials: the adopted agent's host said its launch credential; held again session=count names=[\"CLAUDE_CODE_OAUTH_TOKEN\"]",
      "2026-11-28T18:40:30.000Z  INFO acpmux::hub::spawn: agent launches with no delivered credential: it keeps this machine's route session=felt",
    ].join("\n")
    const life = sessionLife(out, ["count", "felt"], kill)
    expect(life.get("felt")!.atKill).toBe("asleep")
    expect(life.get("count")!.atKill).toBe("awake")
    expect(life.get("felt")!.lines.at(-1)).toContain("+30000 ms")
    expect(life.get("felt")!.lines.at(-1)).toContain("no delivered credential")
  })

  it("a chat with no line is unknown", () => {
    expect(sessionLife("@@now 0\n", ["x"], kill).get("x")!.atKill).toBe("unknown")
  })

  it("the command reads only the given sessions' ids and never takes a non-id", () => {
    const cmd = sessionLifeCommand(["abc-1", "x;rm -rf /"])
    expect(cmd).toContain("session=(abc-1)")
    expect(cmd).not.toContain("rm -rf")
  })
})
