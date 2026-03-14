#!/usr/bin/env node

const fs = require("fs")
const os = require("os")
const path = require("path")
const { pathToFileURL } = require("url")

function fail(message) {
  console.error(`FAIL: ${message}`)
  process.exit(1)
}

function expect(condition, message) {
  if (!condition) {
    fail(message)
  }
}

function render(strings, values) {
  let output = ""
  for (let index = 0; index < strings.length; index += 1) {
    output += strings[index]
    if (index < values.length) {
      output += String(values[index])
    }
  }
  return output.replace(/\s+/g, " ").trim()
}

function includes(commands, expected) {
  return commands.some((command) => command === expected)
}

function starts(commands, expected) {
  return commands.some((command) => command.startsWith(expected))
}

async function main() {
  const source = path.join(__dirname, "..", "Resources", "bin", "opencode-cmux-plugin.js")
  const copy = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-opencode-plugin-")), "plugin.mjs")
  fs.copyFileSync(source, copy)
  const mod = await import(pathToFileURL(copy).href)
  const plugin = mod.CmuxIntegrationPlugin || mod.default
  expect(typeof plugin === "function", "expected an importable OpenCode cmux plugin function")

  const commands = []
  const $ = async (strings, ...values) => {
    commands.push(render(strings, values))
  }

  const hooks = await plugin({ $ })
  expect(hooks && typeof hooks.event === "function", "expected an event hook from the OpenCode cmux plugin")

  async function emit(event) {
    await hooks.event({ event })
    const snapshot = [...commands]
    commands.length = 0
    return snapshot
  }

  let output = await emit({
    type: "session.created",
    properties: { info: { id: "s1" } },
  })
  expect(
    starts(output, "cmux set-status opencode Idle --icon pause.circle.fill --color #8E8E93 --pid "),
    `expected Idle status after session.created, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "session.status",
    properties: { sessionID: "s1", status: { type: "busy" } },
  })
  expect(
    starts(output, "cmux set-status opencode Running --icon bolt.fill --color #4C8DFF --pid "),
    `expected Running status after busy event, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "permission.asked",
    properties: {
      id: "p1",
      sessionID: "s1",
      permission: "bash",
      patterns: ["git status"],
      metadata: {},
      always: [],
    },
  })
  expect(
    includes(output, "cmux notify --title OpenCode --subtitle Permission --body Permission required: bash git status"),
    `expected permission notification, got ${JSON.stringify(output)}`,
  )
  expect(
    starts(output, "cmux set-status opencode Needs input --icon bell.fill --color #4C8DFF --pid "),
    `expected Needs input status for permission prompt, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "session.status",
    properties: { sessionID: "s1", status: { type: "busy" } },
  })
  expect(
    includes(output, "cmux clear-notifications"),
    `expected clear-notifications when work resumes, got ${JSON.stringify(output)}`,
  )
  expect(
    starts(output, "cmux set-status opencode Running --icon bolt.fill --color #4C8DFF --pid "),
    `expected Running status after resume, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "session.status",
    properties: {
      sessionID: "s1",
      status: { type: "retry", attempt: 2, message: "Rate limited", next: Date.now() + 1000 },
    },
  })
  expect(
    starts(output, "cmux set-status opencode Retrying --icon arrow.triangle.2.circlepath --color #FF9500 --pid "),
    `expected Retrying status, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "session.idle",
    properties: { sessionID: "s1" },
  })
  expect(
    starts(output, "cmux set-status opencode Idle --icon pause.circle.fill --color #8E8E93 --pid "),
    `expected Idle status after session.idle, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "question.asked",
    properties: {
      id: "q1",
      sessionID: "s1",
      questions: [
        {
          question: "Continue with deploy?",
          header: "Deploy",
          options: [
            { label: "Yes", description: "Continue" },
            { label: "No", description: "Stop" },
          ],
        },
      ],
    },
  })
  expect(
    includes(output, "cmux notify --title OpenCode --subtitle Question --body Continue with deploy?"),
    `expected question notification, got ${JSON.stringify(output)}`,
  )
  expect(
    starts(output, "cmux set-status opencode Needs input --icon bell.fill --color #4C8DFF --pid "),
    `expected Needs input status for question, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "permission.updated",
    properties: {
      id: "legacy-permission",
      type: "edit",
      pattern: ["src/app.ts"],
      sessionID: "s1",
      messageID: "m1",
      message: "Allow editing src/app.ts",
      metadata: {},
      time: { created: Date.now() },
    },
  })
  expect(
    includes(output, "cmux notify --title OpenCode --subtitle Permission --body Allow editing src/app.ts"),
    `expected legacy permission notification, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "session.error",
    properties: {
      sessionID: "s1",
      error: { message: "Boom" },
    },
  })
  expect(
    includes(output, "cmux notify --title OpenCode --subtitle Error --body Boom"),
    `expected error notification, got ${JSON.stringify(output)}`,
  )
  expect(
    starts(output, "cmux set-status opencode Error --icon exclamationmark.triangle.fill --color #FF3B30 --pid "),
    `expected Error status, got ${JSON.stringify(output)}`,
  )

  output = await emit({
    type: "session.deleted",
    properties: { info: { id: "s1" } },
  })
  expect(
    includes(output, "cmux clear-notifications"),
    `expected notifications to clear when session disappears, got ${JSON.stringify(output)}`,
  )
  expect(
    includes(output, "cmux clear-status opencode"),
    `expected status to clear when session disappears, got ${JSON.stringify(output)}`,
  )

  console.log("PASS: OpenCode cmux plugin maps session events to sidebar status + notifications")
}

main().catch((error) => {
  fail(error instanceof Error ? error.message : String(error))
})
