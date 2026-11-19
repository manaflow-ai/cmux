import { stackServerApp } from "../../../lib/stack";
import { postgresNativeSignInCodeStore } from "../../../lib/native-sign-in-code-store";
import { makeNativeTokenHandler } from "./handler";

export const POST = makeNativeTokenHandler({
  store: postgresNativeSignInCodeStore(),
  getUserById: stackServerApp ? (userId) => stackServerApp.getUser(userId) : null,
});
