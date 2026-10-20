import { describe, expect, test } from "bun:test";
import { DeviceDescriptorSchema } from "../src/contracts/common";
import { RequestSchema } from "../src/contracts/requests";
import { ResponseSchema } from "../src/contracts/responses";
import { descriptor } from "./fixtures";

describe("versioned server boundaries", () => {
  test("rejects private address publication and stale protocol envelopes", () => {
    expect(DeviceDescriptorSchema.safeParse({ ...descriptor, directAddresses: ["192.168.1.1:7777"] }).success).toBe(false);
    expect(DeviceDescriptorSchema.safeParse({ ...descriptor, metadata: { ...descriptor.metadata, directPortV4: 7777 } }).success).toBe(false);
    expect(RequestSchema.safeParse({ v: 1, type: "mint_request", payload: { endpointId: descriptor.endpointId } }).success).toBe(false);
  });
  test("validates URL policy and rejects noninteger revisions", () => {
    for (const url of ["http://relay.example", "https://secret@relay.example", "https://relay.example/?token=secret"]) {
      expect(DeviceDescriptorSchema.safeParse({ ...descriptor, metadata: { ...descriptor.metadata, relayURLs: [url] } }).success).toBe(false);
    }
    expect(ResponseSchema.safeParse({ schemaId: "directory.changed.v1", teamId: "team", revision: 0.5 }).success).toBe(false);
  });
  test("uses a distinct request schema for a new wire version", () => {
    expect(RequestSchema.safeParse({ schemaId: "relay.request.v1", requestId: "request" }).success).toBe(true);
    expect(RequestSchema.safeParse({ schemaId: "relay.request.v2", requestId: "request" }).success).toBe(false);
  });
});
