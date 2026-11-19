import { env } from "../../../env";
import { stackServerApp } from "../../../lib/stack";
import { postgresNativeSignInCodeStore } from "../../../lib/native-sign-in-code-store";
import { makeNativeTokenCapabilityHandler, makeNativeTokenHandler } from "./handler";

const authApp = stackServerApp;
const dependencies = {
  store: postgresNativeSignInCodeStore(),
  getUserById: authApp ? (userId: string) => authApp.getUser(userId) : null,
  issuer: env.NEXT_PUBLIC_STACK_PROJECT_ID,
};

export const GET = makeNativeTokenCapabilityHandler(dependencies);
export const POST = makeNativeTokenHandler(dependencies);
