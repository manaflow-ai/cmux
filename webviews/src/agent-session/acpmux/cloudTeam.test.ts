import { describe, expect, test } from "bun:test";
import { currentCloudTeam, refreshCloudMachines } from "./cloudMachines";

describe("the active team from cloudMachine.list", () => {
  test("a signed-in reply names the team; signed out or a refused read clears it", async () => {
    await refreshCloudMachines(async () => ({
      signedIn: true,
      loaded: true,
      machines: [],
      team: { name: "cmux", personal: false },
    }));
    expect(currentCloudTeam()).toEqual({ name: "cmux", personal: false });

    await refreshCloudMachines(async () => ({ signedIn: false, loaded: false, machines: [], team: { name: "cmux" } }));
    expect(currentCloudTeam()).toBeUndefined();

    await refreshCloudMachines(async () => ({
      signedIn: true,
      loaded: true,
      machines: [],
      team: { name: "Personal", personal: true },
    }));
    expect(currentCloudTeam()).toEqual({ name: "Personal", personal: true });
    await refreshCloudMachines(async () => {
      throw new Error("refused");
    });
    expect(currentCloudTeam()).toBeUndefined();
  });
});
