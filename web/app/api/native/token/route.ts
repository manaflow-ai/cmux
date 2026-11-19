import { stackServerApp } from "../../../lib/stack";
import { postgresNativeSignInCodeStore } from "../../../lib/native-sign-in-code-store";
import { makeNativeTokenHandler } from "./handler";

const authApp = stackServerApp;

export const POST = makeNativeTokenHandler({
  store: postgresNativeSignInCodeStore(),
  getUserById: authApp ? (userId) => authApp.getUser(userId) : null,
});
