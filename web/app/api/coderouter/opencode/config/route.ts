import { openCodeClientConfig } from "../../../../../services/coderouter/opencodeProxy";
import { coderouterControlRoute } from "../../../../../services/coderouter/requestTelemetry";

export const GET = coderouterControlRoute(
  "opencode_config",
  "/api/coderouter/opencode/config",
  (request) => openCodeClientConfig(request),
);
