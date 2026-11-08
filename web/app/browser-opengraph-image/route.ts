import { browserOpenGraphImageResponse } from "@/app/lib/browser-open-graph-image";


export function GET(): Promise<Response> {
  return browserOpenGraphImageResponse();
}
