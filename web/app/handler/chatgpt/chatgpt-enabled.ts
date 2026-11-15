import { env } from "../../env";

/**
 * Whether this deployment offers Sign in with ChatGPT: an OpenAI client ID is
 * set. Kept apart from the routes so the sign-in page does not load them.
 */
export function chatGPTSignInEnabled(): boolean {
  return Boolean(env.CMUX_CHATGPT_SIGNIN_CLIENT_ID);
}
