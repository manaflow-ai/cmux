// Settings > Cloud > Compute (Labs: labs.teamCompute, off by default): the team's monthly Cloud
// allotment and each member's use, the Ledger layout of ComputeCard. The app serves only the read
// (`cmux.settings.cloud.allotment.get`, the Cloud app server's cloud.allotment.get), so the card is
// read-only. Off, it draws nothing, asks the app for nothing, and the page is as before.
import { TEAM_COMPUTE_LAB } from "../computeAllotment";
import { useSettingsSelector } from "../context";
import { valueOf } from "../store";
import { ComputeCard } from "./ComputeCard";

export function CloudComputeCard() {
  const on = useSettingsSelector((state) => valueOf(state, TEAM_COMPUTE_LAB) === true);
  if (!on) return null;
  return <ComputeCard layout="ledger" readOnly explainUnavailable />;
}
