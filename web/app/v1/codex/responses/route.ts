import { POST as handleResponsesRequest } from "../../responses/route";

export const maxDuration = 1_800;

export async function POST(request: Request): Promise<Response> {
  return await handleResponsesRequest(request);
}
