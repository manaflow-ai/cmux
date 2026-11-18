import type { NextRequest } from "next/server";
import { startRoute } from "../chatgpt-routes";

export function GET(request: NextRequest) {
  return startRoute(request);
}
