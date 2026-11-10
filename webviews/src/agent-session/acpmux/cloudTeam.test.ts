import { describe, expect, test } from "bun:test";
import {
  CLOUD_TEAM_CHANGE_EVENT,
  currentCloudTeam,
  followCloudTeamChange,
  refreshCloudMachines,
} from "./cloudMachines";

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

describe("a team change from the app", () => {
  test("reads the list again at once, dropping a read that carries the old team", async () => {
    await refreshCloudMachines(async () => ({
      signedIn: true,
      loaded: true,
      machines: [],
      team: { name: "cmux", personal: false },
    }));
    expect(currentCloudTeam()).toEqual({ name: "cmux", personal: false });

    let release: (value: unknown) => void = () => {};
    const stale = new Promise((resolve) => (release = resolve));
    void refreshCloudMachines(() => stale);

    const target = new EventTarget();
    let reads = 0;
    const stop = followCloudTeamChange(async () => {
      reads += 1;
      return { signedIn: true, loaded: true, machines: [], team: { name: "Personal", personal: true } };
    }, target);
    target.dispatchEvent(new Event(CLOUD_TEAM_CHANGE_EVENT));
    await Promise.resolve();
    await Promise.resolve();
    expect(reads).toBe(1);
    expect(currentCloudTeam()).toEqual({ name: "Personal", personal: true });

    release({ signedIn: true, loaded: true, machines: [], team: { name: "cmux", personal: false } });
    await stale;
    await Promise.resolve();
    expect(currentCloudTeam()).toEqual({ name: "Personal", personal: true });
    stop();
    target.dispatchEvent(new Event(CLOUD_TEAM_CHANGE_EVENT));
    expect(reads).toBe(1);
  });
});
