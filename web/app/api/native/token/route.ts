import { connection } from "next/server";
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

const capability = makeNativeTokenCapabilityHandler(dependencies);

export async function GET(): Promise<Response> {
  // Never prerendered: the app reads this per sign-in, and the answer
  // (Cache-Control: no-store) must come from the running deployment.
  await connection();
  return capability();
}

export const POST = makeNativeTokenHandler(dependencies);
