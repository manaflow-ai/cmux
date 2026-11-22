import { describe, expect, test } from "bun:test"
import { canCancel, canUndo, fraction, type Job, type JobEvent, newJob, reduceJob, secondsLeft } from "../src/model/jobs.ts"

const start = () => newJob({ id: "job_1", op: "copy", subject: "3 items", destination: "acme", crossHost: true, at: 0 })
const ev = (j: Job, event: JobEvent, at = 1000) => reduceJob(j, { type: "event", event, at })
const conflict = { item: "a.txt", existing: { size: 1, mtime: 1 }, incoming: { size: 2, mtime: 2 } }

describe("copy job state machine", () => {
  test("queued -> preparing -> running -> done with undo", () => {
    let j = start()
    expect(j.phase).toBe("queued")
    j = ev(j, { kind: "preparing", seq: 1, items_total: 3, bytes_total: 300 })
    expect(j.phase).toBe("preparing")
    j = ev(j, { kind: "progress", seq: 2, bytes_done: 150, items_done: 1 })
    expect(j.phase).toBe("running")
    expect(fraction(j)).toBe(0.5)
    j = ev(j, { kind: "done", seq: 3, undo: "undo_1" })
    expect(j.phase).toBe("done")
    expect(j.bytes.done).toBe(300)
    expect(fraction(j)).toBe(1)
    expect(canUndo(j)).toBe(true)
    expect(canCancel(j)).toBe(false)
  })

  test("late, repeated and backward events change nothing", () => {
    let j = ev(start(), { kind: "progress", seq: 5, bytes_done: 50, items_done: 1, bytes_total: 100 })
    expect(ev(j, { kind: "progress", seq: 5, bytes_done: 90, items_done: 2 })).toBe(j)
    expect(ev(j, { kind: "progress", seq: 4, bytes_done: 90, items_done: 2 })).toBe(j)
    j = ev(j, { kind: "progress", seq: 6, bytes_done: 40, items_done: 1 })
    expect(j.bytes.done).toBe(50)
  })

  test("a conflict pauses until the owner reports it resolved", () => {
    let j = ev(start(), { kind: "progress", seq: 1, bytes_done: 10, items_done: 0, bytes_total: 100 })
    j = ev(j, { kind: "conflict", seq: 2, conflict })
    expect(j.phase).toBe("conflict")
    j = reduceJob(j, { type: "requestResolve" })
    expect(j.pending).toBe("resolve")
    j = ev(j, { kind: "progress", seq: 3, bytes_done: 20, items_done: 0 })
    expect(j.phase).toBe("conflict")
    j = ev(j, { kind: "resolved", seq: 4 })
    expect(j.phase).toBe("running")
    expect(j.conflict).toBeNull()
    expect(j.pending).toBeNull()
  })

  test("cancel is a request until the owner confirms; terminal states absorb", () => {
    let j = ev(start(), { kind: "progress", seq: 1, bytes_done: 10, items_done: 0 })
    j = reduceJob(j, { type: "requestCancel" })
    expect(j.pending).toBe("cancel")
    expect(canCancel(j)).toBe(false)
    j = ev(j, { kind: "cancelling", seq: 2 })
    j = ev(j, { kind: "cancelled", seq: 3 })
    expect(j.phase).toBe("cancelled")
    expect(ev(j, { kind: "progress", seq: 4, bytes_done: 99, items_done: 1 })).toBe(j)
    expect(ev(j, { kind: "done", seq: 5 })).toBe(j)
  })

  test("a refused request clears pending and keeps the error", () => {
    let j = reduceJob(start(), { type: "requestCancel" })
    j = reduceJob(j, { type: "requestFailed", error: { code: "operation.unsupported", message: "no" } })
    expect(j.pending).toBeNull()
    expect(j.error?.code).toBe("operation.unsupported")
  })

  test("events not allowed in the current phase are ignored", () => {
    const j = start()
    expect(ev(j, { kind: "resolved", seq: 1 })).toBe(j)
    const running = ev(j, { kind: "progress", seq: 1, bytes_done: 1, items_done: 0 })
    expect(ev(running, { kind: "preparing", seq: 2 })).toBe(running)
  })

  test("failure keeps the owner's error", () => {
    const j = ev(start(), { kind: "failed", seq: 1, error: { code: "host.unreachable", message: "acme went away" } })
    expect(j.phase).toBe("failed")
    expect(j.error?.message).toBe("acme went away")
  })

  test("time left: the owner's estimate first, else the average rate", () => {
    let j = ev(start(), { kind: "progress", seq: 1, bytes_done: 100, bytes_total: 400, items_done: 0 }, 10_000)
    expect(secondsLeft(j, 10_000)).toBe(30)
    j = ev(j, { kind: "progress", seq: 2, bytes_done: 200, items_done: 0, eta_s: 7 }, 11_000)
    expect(secondsLeft(j, 11_000)).toBe(7)
    expect(fraction(newJob({ id: "job_2", op: "trash", subject: "x", destination: "Trash", crossHost: false, at: 0 }))).toBeNull()
  })
})
