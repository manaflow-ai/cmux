import type { NextRequest } from "next/server";
import { linkRoute } from "../chatgpt-routes";

export function GET(request: NextRequest) {
  return linkRoute(request);
}
