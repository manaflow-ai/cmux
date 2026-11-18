// The roll table: every Chief you can pull, its rarity, and the odds. Add a Chief by dropping
// assets/chiefs/<id>.png (and a flat silhouette at assets/missing/<id>.png) and a line here.

export type Rarity = "common" | "rare" | "epic" | "legendary"
export interface Chief { id: string; name: string; rarity: Rarity }

export const CHIEFS: Chief[] = [
  { id: "bolt", name: "Bolt", rarity: "common" },
  { id: "captain", name: "Captain", rarity: "common" },
  { id: "mochi", name: "Mochi", rarity: "common" },
  { id: "sprout", name: "Sprout", rarity: "common" },
  { id: "orb", name: "Orb", rarity: "common" },
  { id: "moon", name: "Moon", rarity: "common" },
  { id: "fox", name: "Fox", rarity: "rare" },
  { id: "machine", name: "Machine", rarity: "rare" },
  { id: "machine-blue", name: "Blue Machine", rarity: "rare" },
  { id: "moon-blue", name: "Blue Moon", rarity: "rare" },
  { id: "orb-hood", name: "Hooded Orb", rarity: "rare" },
  { id: "machine-cyan", name: "Cyan Machine", rarity: "epic" },
  { id: "machine-violet", name: "Violet Machine", rarity: "epic" },
  { id: "moon-rose", name: "Rose Moon", rarity: "epic" },
  { id: "orb-spark", name: "Spark Orb", rarity: "epic" },
  { id: "machine-gold", name: "Gold Machine", rarity: "legendary" },
  { id: "fox-arctic", name: "Arctic Fox", rarity: "legendary" }
]

/** Each tier's look and odds (percent). Ten pulls in a row without epic or better make the next one epic or better. */
export const RARITY: Record<Rarity, { label: string; stars: string; odds: number; color: string; colors: string[] }> = {
  common: { label: "Common", stars: "★", odds: 55, color: "#98989D", colors: ["#B8B8BE", "#7C7C84"] },
  rare: { label: "Rare", stars: "★★", odds: 30, color: "#0A84FF", colors: ["#64D2FF", "#0A84FF"] },
  epic: { label: "Epic", stars: "★★★", odds: 11, color: "#AE81FF", colors: ["#E0B0FF", "#7D4CDB"] },
  legendary: { label: "Legendary", stars: "★★★★", odds: 4, color: "#FF9F0A", colors: ["#FFE066", "#FF9F0A", "#FF6B3D"] }
}
export const PITY = 10

export const image = (c: Chief) => `assets/chiefs/${c.id}.png`
export const silhouette = (c: Chief) => `assets/missing/${c.id}.png`
export const isBig = (r: Rarity) => r === "epic" || r === "legendary"

/** One pull: a tier by its odds (at least epic once the pity count is reached), then a Chief of that tier. */
export function roll(sinceBig: number, random = Math.random): Chief {
  let rarity: Rarity = "common"
  let n = random() * 100
  for (const r of ["legendary", "epic", "rare", "common"] as Rarity[]) {
    if (n < RARITY[r].odds) { rarity = r; break }
    n -= RARITY[r].odds
  }
  if (sinceBig + 1 >= PITY && !isBig(rarity)) rarity = random() * 15 < 4 ? "legendary" : "epic"
  const tier = CHIEFS.filter((c) => c.rarity === rarity)
  return tier[Math.floor(random() * tier.length)]!
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
/** "Nov 15" (UTC: the sandbox has no Intl). */
export const day = (ms: number) => { const d = new Date(ms); return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}` }
