// The Chief pet characters' art (ChiefPetCard.tsx), in a chunk of its own. Imported, not
// `new URL(..., import.meta.url)`: the shipped page's CSP allows `img-src data:` only, so its bundler
// (bundle.mjs) inlines each PNG as a data URL, about 850 KB of base64 the Settings page's first load
// no longer carries. ChiefPetCard.tsx starts loading this module when it evaluates.
import mascotFox from "../../../agent-session/acpmux/mascots/ChiefMascotFox.png";
import mascotMachine from "../../../agent-session/acpmux/mascots/ChiefMascotMachine.png";
import mascotMachineCyan from "../../../agent-session/acpmux/mascots/ChiefMascotMachineCyan.png";
import mascotMachineBlue from "../../../agent-session/acpmux/mascots/ChiefMascotMachineBlue.png";
import mascotMoon from "../../../agent-session/acpmux/mascots/ChiefMascotMoon.png";
import mascotMoonBlue from "../../../agent-session/acpmux/mascots/ChiefMascotMoonBlue.png";
import mascotMochi from "../../../agent-session/acpmux/mascots/ChiefMascotMochi.png";
import mascotCaptain from "../../../agent-session/acpmux/mascots/ChiefMascotCaptain.png";
import mascotSprout from "../../../agent-session/acpmux/mascots/ChiefMascotSprout.png";
import mascotBolt from "../../../agent-session/acpmux/mascots/ChiefMascotBolt.png";
import mascotFoxArctic from "../../../agent-session/acpmux/mascots/ChiefMascotFoxArctic.png";
import mascotMachineViolet from "../../../agent-session/acpmux/mascots/ChiefMascotMachineViolet.png";
import mascotMachineGold from "../../../agent-session/acpmux/mascots/ChiefMascotMachineGold.png";
import mascotMoonRose from "../../../agent-session/acpmux/mascots/ChiefMascotMoonRose.png";
import mascotOrb from "../../../agent-session/acpmux/mascots/ChiefMascotOrb.png";
import mascotOrbSpark from "../../../agent-session/acpmux/mascots/ChiefMascotOrbSpark.png";
import mascotOrbHood from "../../../agent-session/acpmux/mascots/ChiefMascotOrbHood.png";

/** Each character's art by id (`HomeChiefPetSetting.mascots`). */
export const CHIEF_PET_ART: Readonly<Record<string, string>> = {
  fox: mascotFox,
  machine: mascotMachine,
  "machine-cyan": mascotMachineCyan,
  "machine-blue": mascotMachineBlue,
  moon: mascotMoon,
  "moon-blue": mascotMoonBlue,
  mochi: mascotMochi,
  captain: mascotCaptain,
  sprout: mascotSprout,
  bolt: mascotBolt,
  "fox-arctic": mascotFoxArctic,
  "machine-violet": mascotMachineViolet,
  "machine-gold": mascotMachineGold,
  "moon-rose": mascotMoonRose,
  orb: mascotOrb,
  "orb-spark": mascotOrbSpark,
  "orb-hood": mascotOrbHood,
};
