import { accountMeProcedure } from "./account/me";
import { cloudDevicesProcedure } from "./cloud/devices";

export const router = {
  account: {
    me: accountMeProcedure,
  },
  dashboard: {
    cloud: {
      devices: cloudDevicesProcedure,
    },
  },
};

export type AppRouter = typeof router;
