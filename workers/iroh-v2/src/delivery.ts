import { z } from "zod";
import { DeliveryReceiptSchema, revision } from "./contracts/common";
import type { ControlResponse } from "./contracts/responses";
import { encodeResponse } from "./boundary";
import { encodeBase64URL } from "./crypto";
import { OperationError } from "./errors";

export const CONNECTION_OUTPUT_BYTES = 2 * 1024 * 1024;
export const CONNECTION_OUTPUT_MESSAGES = 1024;
export const USER_OUTPUT_BYTES = 8 * 1024 * 1024;
export const USER_OUTPUT_MESSAGES = 4096;
const CHECKPOINT_MESSAGES = 16;
const CHECKPOINT_BYTES = 64 * 1024;
const encoder = new TextEncoder();

const CheckpointSchema = DeliveryReceiptSchema.extend({ bytes: revision, messages: revision });
export const DeliveryStateSchema = z.strictObject({
  sequence: revision,
  acknowledgedSequence: revision,
  checkpoints: z.array(CheckpointSchema).max(128),
  pendingBytes: revision,
  pendingMessages: revision,
});
export type DeliveryState = z.infer<typeof DeliveryStateSchema>;
export type PreparedDelivery = { text: string; state: DeliveryState; bytes: number; messages: number };

export function emptyDeliveryState(): DeliveryState {
  return { sequence: 0, acknowledgedSequence: 0, checkpoints: [], pendingBytes: 0, pendingMessages: 0 };
}

/** Unacknowledged bytes conservatively include the runtime's transport buffer. */
export function deliveryUsage(state: DeliveryState): { bytes: number; messages: number } {
  return state.checkpoints.reduce((usage, point) => ({ bytes: usage.bytes + point.bytes, messages: usage.messages + point.messages }), {
    bytes: state.pendingBytes, messages: state.pendingMessages,
  });
}

/** Pure preparation lets the user DO reserve capacity before enqueueing output. */
export function prepareDelivery(state: DeliveryState, response: ControlResponse): PreparedDelivery {
  const sequence = state.sequence + 1;
  const plain = encodeResponse(response);
  const checkpoint = state.pendingMessages + 1 >= CHECKPOINT_MESSAGES || state.pendingBytes + encoder.encode(plain).byteLength >= CHECKPOINT_BYTES;
  const receipt = checkpoint ? { sequence, token: encodeBase64URL(crypto.getRandomValues(new Uint8Array(16))) } : undefined;
  const text = receipt ? encodeResponse({ ...response, deliveryReceipt: receipt }) : plain;
  const size = encoder.encode(text).byteLength;
  const next: DeliveryState = {
    ...state, sequence, checkpoints: [...state.checkpoints],
    pendingBytes: state.pendingBytes + size, pendingMessages: state.pendingMessages + 1,
  };
  if (receipt) {
    next.checkpoints.push({ ...receipt, bytes: next.pendingBytes, messages: next.pendingMessages });
    next.pendingBytes = 0;
    next.pendingMessages = 0;
  }
  const usage = deliveryUsage(next);
  if (usage.bytes > CONNECTION_OUTPUT_BYTES || usage.messages > CONNECTION_OUTPUT_MESSAGES || next.checkpoints.length > 128) {
    throw new OperationError("slow_consumer", 429, true, 1000);
  }
  return { text, state: next, ...usage };
}

/** The unpredictable token follows all output it acknowledges on the wire. */
export function acknowledgeDelivery(state: DeliveryState, sequence: number, token: string): DeliveryState {
  if (sequence <= state.acknowledgedSequence) return state;
  const index = state.checkpoints.findIndex(point => point.sequence === sequence && point.token === token);
  if (index < 0) throw new OperationError("invalid_request", 400);
  return { ...state, acknowledgedSequence: sequence, checkpoints: state.checkpoints.slice(index + 1) };
}
