import { accountMeProcedure } from "./account/me";

export const router = {
  account: {
    me: accountMeProcedure,
  },
};

export type AppRouter = typeof router;
