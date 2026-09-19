import { accountMeProcedure } from "./account/me";
import { cloudDevicesProcedure } from "./cloud/devices";
import { billingStatusProcedure } from "./billing/dashboard";
import { coderouterDashboardProcedure } from "./coderouter/dashboard";
import { testflightStatusProcedure } from "./testflight/status";
import {
  vaultOverviewProcedure,
  vaultSessionDetailProcedure,
  vaultSessionListProcedure,
} from "./vault/dashboard";

export const router = {
  account: {
    me: accountMeProcedure,
  },
  dashboard: {
    billing: {
      status: billingStatusProcedure,
    },
    coderouter: {
      overview: coderouterDashboardProcedure,
    },
    cloud: {
      devices: cloudDevicesProcedure,
    },
    testflight: {
      status: testflightStatusProcedure,
    },
    vault: {
      overview: vaultOverviewProcedure,
      sessions: vaultSessionListProcedure,
      session: vaultSessionDetailProcedure,
    },
  },
};

export type AppRouter = typeof router;
