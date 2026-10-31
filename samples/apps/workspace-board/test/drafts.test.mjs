// Manual regression: run on a Freestyle VM with `node --test samples/apps/workspace-board/test/drafts.test.mjs`.
// This exercises the sample's actual script without a browser or third-party dependencies.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { setImmediate } from "node:timers/promises"
import test from "node:test"
import vm from "node:vm"

const source = readFileSync(new URL("../web/app.js", import.meta.url), "utf8")

async function board() {
  const document = { activeElement: null }
  class Element {
    constructor(tag) {
      this.tag = tag
      this.children = []
      this.dataset = {}
      this.value = ""
      this.selectionStart = 0
      this.selectionEnd = 0
      this.selectionDirection = "none"
      this.listeners = new Map()
      this.classList = { toggle() {} }
    }
    append(...nodes) { this.children.push(...nodes) }
    replaceChildren(...nodes) {
      if (this.querySelectorAll("input").includes(document.activeElement)) document.activeElement = null
      this.children = nodes
    }
    querySelectorAll(tag) {
      return this.children.flatMap((node) => [
        ...(node.tag === tag ? [node] : []), ...node.querySelectorAll(tag),
      ])
    }
    setAttribute() {}
    addEventListener(name, callback) { this.listeners.set(name, callback) }
    focus() { document.activeElement = this }
    setSelectionRange(start, end, direction) {
      this.selectionStart = start
      this.selectionEnd = end
      this.selectionDirection = direction
    }
  }
  const nodes = { board: new Element("main"), status: new Element("p"), refresh: new Element("button") }
  Object.assign(document, {
    getElementById: (id) => nodes[id],
    createElement: (tag) => new Element(tag),
  })
  const timers = []
  let pendingList = null
  let pendingWrite = null
  const cmux = {
    call: async (op) => {
      if (op === "workspace.list") return { value: [{ id: "ws1", name: "Sample" }] }
      if (op === "terminal.list") {
        if (pendingList) await pendingList
        return { value: [{ id: "t1", title: "Sample terminal" }] }
      }
      if (op === "terminal.input.write") {
        if (pendingWrite) await pendingWrite
        return { value: null }
      }
      throw new Error(`Unexpected operation: ${op}`)
    },
  }
  vm.runInNewContext(source, {
    document, cmux, console,
    setInterval: (callback, milliseconds) => timers.push({ callback, milliseconds }),
  })
  await setImmediate()
  return {
    document,
    input: () => nodes.board.querySelectorAll("input")[0],
    refresh: () => nodes.refresh.listeners.get("click")(),
    submit: () => nodes.board.querySelectorAll("form")[0].listeners.get("submit")({ preventDefault() {} }),
    holdWrite: () => {
      let release
      pendingWrite = new Promise((resolve) => { release = resolve })
      return release
    },
    holdList: () => {
      let release
      pendingList = new Promise((resolve) => { release = resolve })
      return release
    },
    advance: async (milliseconds) => {
      for (const timer of timers) {
        for (let elapsed = timer.milliseconds; elapsed <= milliseconds; elapsed += timer.milliseconds) {
          await timer.callback()
        }
      }
    },
  }
}

test("an unfinished command survives six seconds of idle time", async () => {
  const app = await board()
  const input = app.input()
  input.value = "echo an unfinished command"
  input.focus()
  await app.advance(6000)
  assert.equal(app.input().value, "echo an unfinished command")
  assert.equal(app.document.activeElement, app.input())
})

test("refresh preserves edits made while its request is pending and the selection", async () => {
  const app = await board()
  const release = app.holdList()
  const refreshing = app.refresh()
  const input = app.input()
  input.value = "echo the newest draft"
  input.focus()
  input.setSelectionRange(5, 8, "backward")
  release()
  await refreshing
  assert.equal(app.input().value, "echo the newest draft")
  assert.equal(app.document.activeElement, app.input())
  assert.equal(app.input().selectionStart, 5)
  assert.equal(app.input().selectionEnd, 8)
  assert.equal(app.input().selectionDirection, "backward")
})

test("a send completing after refresh clears the visible command", async () => {
  const app = await board()
  const release = app.holdWrite()
  const input = app.input()
  input.value = "echo a single send"
  app.submit()
  await app.refresh()
  release()
  await setImmediate()
  assert.equal(app.input().value, "")
})
