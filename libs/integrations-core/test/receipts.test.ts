import { describe, expect, test } from "bun:test"
import {
  buildGitHubDispatchRequest,
  buildReceiptWebhookRequest,
  buildSlackWebhookRequest,
  receiptCloudEvent,
  ReceiptEndpointError,
  type CmuxReceipt
} from "../src/receipts.ts"

const receipt: CmuxReceipt = {
  id: "op_01j9r7z0f0",
  type: "cloud.machine.ready",
  source: "cmux://machine/vm_demo",
  status: "succeeded",
  occurred_at: "2026-10-24T05:30:00.000Z",
  operation: "attach",
  resource: { kind: "machine", id: "vm_demo" },
  duration_ms: 842,
  details: { provider: "gcp", zone: "us-west1-a" }
}

describe("receipt contract", () => {
  test("builds a CloudEvents envelope without adding credentials", () => {
    const event = receiptCloudEvent(receipt)
    expect(event).toEqual({
      specversion: "1.0",
      id: receipt.id,
      source: receipt.source,
      type: receipt.type,
      time: receipt.occurred_at,
      datacontenttype: "application/json",
      data: receipt
    })
    expect(JSON.stringify(event)).not.toContain("Authorization")
  })

  test("generic and provider payloads are deterministic and POST-only", () => {
    const generic = buildReceiptWebhookRequest("https://hooks.example.com/cmux", receipt)
    expect(generic.method).toBe("POST")
    expect(generic.headers).toEqual({ "content-type": "application/cloudevents+json" })
    expect(JSON.parse(generic.body)).toMatchObject({ specversion: "1.0", data: receipt })

    const github = buildGitHubDispatchRequest("https://api.github.com/repos/acme/demo/dispatches", receipt)
    expect(JSON.parse(github.body)).toEqual({ event_type: receipt.type, client_payload: receipt })
    expect(github.headers).toEqual({ "content-type": "application/json" })

    const slack = buildSlackWebhookRequest("https://hooks.slack.com/services/T/B/X", receipt)
    expect(JSON.parse(slack.body)).toEqual({ text: "[cmux] cloud.machine.ready succeeded: machine/vm_demo" })
  })
})

describe("receipt endpoint guard", () => {
  test("rejects credentials, private hosts and non-HTTPS URLs", () => {
    const cases = [
      ["https://user:secret@hooks.example.com/", "receipt.credentials_in_url"],
      ["http://hooks.example.com/", "receipt.https_required"],
      ["https://127.0.0.1/hook", "receipt.private_endpoint"],
      ["file:///tmp/hook", "receipt.invalid_endpoint"]
    ] as const
    for (const [url, code] of cases) {
      try {
        buildReceiptWebhookRequest(url, receipt)
        throw new Error(`expected ${code}`)
      } catch (error) {
        expect(error).toBeInstanceOf(ReceiptEndpointError)
        expect((error as ReceiptEndpointError).code).toBe(code)
      }
    }
  })
})
