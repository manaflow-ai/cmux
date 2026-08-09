import { captureInstallEvent } from "../../../services/analytics/install";


export function GET(request: Request): Response {
  captureInstallEvent({
    event: "website_install_script_requested",
    product: "tui",
    method: "curl",
  });
  return Response.redirect(new URL("/tui/install-static.sh", request.url), 307);
}
