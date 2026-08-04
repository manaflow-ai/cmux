import { accountMeProcedure } from "./account/me";
import { srAccountsListProcedure, srAccountsPushProcedure } from "./sr/accounts";
import { srDevicePollProcedure, srDeviceStartProcedure } from "./sr/device";

export const router = {
  account: {
    me: accountMeProcedure,
  },
  sr: {
    device: {
      start: srDeviceStartProcedure,
      poll: srDevicePollProcedure,
    },
    accounts: {
      push: srAccountsPushProcedure,
      list: srAccountsListProcedure,
    },
  },
};

export type AppRouter = typeof router;
