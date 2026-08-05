import { vmErrorResponse } from "../../../services/vms/routeHelpers";

export function devboxNotFoundResponse(): Response {
  return vmErrorResponse({
    error: "devbox_not_found",
    status: 404,
    message: "This account has no active devbox.",
    action: "Create one with `POST /api/devbox`.",
  });
}
