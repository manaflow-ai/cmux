import type { NextRequest } from "next/server";
import { callbackRoute } from "../chatgpt-routes";

export function GET(request: NextRequest) {
  return callbackRoute(request);
}
