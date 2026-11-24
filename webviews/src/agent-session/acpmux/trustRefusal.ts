// A prompt acpmux refused because the session's folder has no Trust answer (`trust_gate.rs`): the
// refusal's reason and folder. Its bodies live in direct/refusals.ts, so the trust ask and its
// callers read it without the connection client.
export { isTrustRefusal, trustRefusal, type TrustRefusal } from "./direct/refusals";
