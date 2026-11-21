import { handleRepos } from "@/app/extensions/_lib/link";
import { LINK_SIGN_IN_URL, linkDeps } from "@/app/extensions/_lib/link-session";

/** The person's public GitHub repos (search and paging), the listed ones marked. */
export async function GET(request: Request): Promise<Response> {
  return handleRepos(request, linkDeps(), LINK_SIGN_IN_URL);
}
