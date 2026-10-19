import { proxyCodexRequest } from "../../../services/coderouter/codexProxy";
import {
  coderouterUnavailable,
  withCoderouterRoute,
} from "../../../services/coderouter/requestTelemetry";

export const maxDuration = 1_800;

export const POST = withCoderouterRoute(
  { surface: "responses", route: "/v1/responses", unavailable: coderouterUnavailable },
  (request) => proxyCodexRequest(request),
);
