// The prod journey's reserved home chat sent right after agent-session-start and was refused
// `agent_session.not_attached` (cloud-journey-prod run 45576305580): the daemon takes a prompt only on a tab attached
// on this connection (agent_session_attach.rs `(None, _) => refuse(.., Refusal::NotAttached)`). A fake dial keeps
// that rule; ChatClient.startAttached attaches before the send, as the app does.
import { describe, expect, it } from "bun:test"
import { ChatClient, replayOf, resumeText, type ChaosContext, type DialLike } from "./cloud-chaos.ts"

const ctx: ChaosContext = { cmux: "cmux", env: {}, machine: "m", exec: (async () => ({ code: 0, stdout: "", stderr: "" })) as any, guest: "", session: "s", tag: "t" } as ChaosContext

/** A daemon on one connection: one chat tab (surface 7), started as session "sess", attached only by agent-session-attach. */
function fakeDaemon(start: any = { ok: true, data: { session: "sess" } }) {
  const seen: string[] = []
  let attached = false
  const make = (_onLine: (m: any) => void, onDial: () => void): DialLike => ({
    dials: 1,
    start: () => queueMicrotask(onDial),
    stop: () => {},
    request: async (frame) => {
      seen.push(String(frame.cmd))
      switch (frame.cmd) {
        case "identify": return { ok: true, data: { registry_id: "r" } }
        case "create-workspace": return { ok: true, data: { workspace: 1 } }
        case "new-conversation-tab": return { ok: true, data: { surface: 7, tab_resource_id: "tab-1" } }
        case "agent-session-start": return start
        case "agent-session-attach": attached = true; return { ok: true, data: { lastSeq: 3, events: [] } }
        case "list-workspaces": return { ok: true, data: { workspaces: [{ screens: [{ panes: [{ tabs: [{ surface: 7, tab_resource_id: "tab-1" }] }] }] }] } }
        case "agent-session-prompt":
          return attached ? { ok: true, data: {} } : { ok: false, error_code: "agent_session.not_attached", error: { message: "the tab is not attached on this connection" } }
        default: return { ok: false, error_code: "unknown" }
      }
    },
  })
  return { seen, make }
}

describe("ChatClient send after a reserved home start", () => {
  it("a bare start then a prompt is refused not_attached (the prod journey's failure)", async () => {
    const d = fakeDaemon()
    const chat = new ChatClient(ctx, d.make)
    await chat.openTab("claude")
    await chat.start("claude")
    await expect(chat.prompt("hi")).rejects.toThrow("agent_session.not_attached")
    chat.stop()
  })

  it("startAttached attaches before the send, so the prompt is taken", async () => {
    const d = fakeDaemon()
    const chat = new ChatClient(ctx, d.make)
    await chat.openTab("claude")
    const reply = await chat.startAttached("claude")
    expect(reply.data.session).toBe("sess")
    expect(chat.session).toBe("sess")
    expect(chat.isAttached).toBe(true)
    await chat.prompt("hi")
    expect(d.seen.slice(-4)).toEqual(["agent-session-start", "agent-session-attach", "list-workspaces", "agent-session-prompt"])
    chat.stop()
  })

  it("a refused start comes back as it came, with no attach", async () => {
    const refused = { ok: false, error_code: "agent_session.sign_in_required", data: { harness: "claude" } }
    const d = fakeDaemon(refused)
    const chat = new ChatClient(ctx, d.make)
    await chat.openTab("claude")
    expect(await chat.startAttached("claude")).toBe(refused)
    expect(d.seen).not.toContain("agent-session-attach")
    chat.stop()
  })
})

describe("each fault's resume facts", () => {
  it("a replay is the seq range its pages delivered, live pushes aside", () => {
    const received = [
      { seq: 40, via: "live" },
      { seq: 41, via: "page" },
      { seq: 42, via: "page" },
      { seq: 43, via: "live" },
      { seq: 44, via: "page" },
    ]
    expect(replayOf(40, received, 1)).toEqual({ after_seq: 40, first: 41, last: 44 })
    expect(replayOf(44, received, 5)).toEqual({ after_seq: 44, first: null, last: null })
  })

  it("the detail names the drop, the acked seq and each replay", () => {
    expect(resumeText({ drop_at: "step 34 of 100 (seq 40)", acked_seq: 40, replays: [{ after_seq: 40, first: 41, last: 77 }, { after_seq: 77, first: null, last: null }] }))
      .toBe("dropped at step 34 of 100 (seq 40), acked seq 40, replayed 41..77 after 40, nothing after 77")
    expect(resumeText({ drop_at: "step 34 of 100 (seq 40)", acked_seq: 40, replays: [] })).toContain("replayed no re-attach")
  })
})
