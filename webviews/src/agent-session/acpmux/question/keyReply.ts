// A native Return submission shares the client's pending RPC map with ordinary card replies.
// Its promise reaches only the matching card; the native host still owns the proof and send.
export const QUESTION_KEY_REQUEST_EVENT = "cmux.question.key-request";

export type QuestionKeyRequest = { id: string; sessionId: string; permissionId: string };
export type QuestionKeyRequestEvent = CustomEvent<QuestionKeyRequest & { result: Promise<unknown> }>;

export function isQuestionKeyRequest(value: unknown): value is QuestionKeyRequest {
  if (!value || typeof value !== "object") return false;
  const request = value as Partial<QuestionKeyRequest>;
  return (
    typeof request.id === "string" &&
    request.id.startsWith("question-key-") &&
    typeof request.sessionId === "string" &&
    typeof request.permissionId === "string"
  );
}

export function deliverQuestionKeyRequest(request: QuestionKeyRequest, result: Promise<unknown>): void {
  // A card can disappear between the physical key and this notification (a session switch).
  // Keep its request tracked for cleanup even when nobody is left to display the result.
  void result.catch(() => undefined);
  window.dispatchEvent(new window.CustomEvent(QUESTION_KEY_REQUEST_EVENT, { detail: { ...request, result } }));
}
