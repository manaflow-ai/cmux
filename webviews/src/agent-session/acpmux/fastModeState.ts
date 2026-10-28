export type FastModeState = {
  currentValue?: string;
  onValue: string;
  offValue: string;
};

/** Fast may expose several on tiers; every value other than the explicit off value is on. */
export function fastModeIsOn(state: FastModeState): boolean {
  return state.currentValue !== undefined && state.currentValue !== state.offValue;
}

/** Toggle a Fast option while preserving the harness's configured on and off values. */
export function nextFastModeValue(state: FastModeState): string {
  return fastModeIsOn(state) ? state.offValue : state.onValue;
}
