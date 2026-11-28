import { handleLink, handleStatus, handleUnlink } from "@/app/extensions/_lib/link";
import { LINK_SIGN_IN_URL, linkDeps } from "@/app/extensions/_lib/link-session";

/** The person's GitHub connection, for the link page. */
export async function GET(request: Request): Promise<Response> {
  return handleStatus(request, linkDeps(), LINK_SIGN_IN_URL);
}

/** Link one of the person's repos to its cmux.com extension page. */
export async function POST(request: Request): Promise<Response> {
  return handleLink(request, linkDeps(), LINK_SIGN_IN_URL);
}

/** Unlink a repo the person linked. */
export async function DELETE(request: Request): Promise<Response> {
  return handleUnlink(request, linkDeps(), LINK_SIGN_IN_URL);
}
