import { setup } from "rivetkit";
import { cmuxHive } from "../services/hive/actor";

export const registry = setup({
  use: { cmuxHive },
});

