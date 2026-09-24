import { POSTWithProtocol } from "../route";

export const maxDuration = 45;

export async function POST(request: Request): Promise<Response> {
  return POSTWithProtocol(request, "e2e-v1");
}
