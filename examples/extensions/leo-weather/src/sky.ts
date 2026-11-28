// The sky of leo-weather: its gradient by the hour, and the animated layers for a condition. Sun,
// moon and clouds are drawn from shapes, so every renderer draws them the same.
import { Capsule, Circle, Particles, ZStack, type View } from "cmux-extension-sdk"
import { describe, type Reading } from "./weather.ts"

// The sky behind everything: a gradient by the place's hour, grayer under cloud.
export function skyColors(r: Reading): string[] {
  const { kind } = describe(r.code)
  if (kind === "snow") return r.day ? ["#8FA5BD", "#DCE6EF"] : ["#1E2635", "#47556B"]
  if (kind !== "clear") return r.day ? ["#4E5E72", "#98A6B4"] : ["#121822", "#2C3442"]
  if (!r.day) return ["#070B1E", "#1B2A4E"]
  if (r.hour < 8) return ["#45558A", "#F4A984"]
  if (r.hour >= 17) return ["#2D3A6B", "#F28C6B"]
  return ["#2F7FD8", "#9CD3F7"]
}

const box = (w: number, h: number) => ({ width: w, height: h })
function sun(s: number): View {
  return ZStack([
    Circle().stroke("#FFE08A").strokeWidth(4 * s).trim({ from: 0, to: 0.8 }).frame(box(118 * s, 118 * s)).loop({ effect: "spin", period: 6 }),
    Circle().fill("#FFD45A").frame(box(84 * s, 84 * s)).glow({ color: "#FFC83D", radius: 40 * s, opacity: 0.9 })
  ]).frame(box(124 * s, 124 * s))
}
function moon(s: number): View {
  return ZStack([
    Circle().fill("#F4F1DE").frame(box(70 * s, 70 * s)).glow({ color: "#DCE3FF", radius: 26 * s, opacity: 0.7 }),
    Circle().fill("#0B1430").frame(box(58 * s, 58 * s)).offset({ x: 20 * s, y: -12 * s })
  ]).frame(box(80 * s, 80 * s)).loop({ effect: "breathe", period: 5, amount: 0.3 })
}
function cloud(s: number, tone: string): View {
  return ZStack([
    Capsule().fill(tone).frame(box(130 * s, 46 * s)).offset({ y: 18 * s }),
    Circle().fill(tone).frame(box(60 * s, 60 * s)).offset({ x: -26 * s, y: -2 * s }),
    Circle().fill(tone).frame(box(78 * s, 78 * s)).offset({ x: 16 * s, y: -10 * s })
  ]).frame(box(140 * s, 100 * s))
}

// The animated layers of a sky, sized by `s` (1 = a full tab).
export function weatherLayers(r: Reading, s: number): View[] {
  const d = describe(r.code)
  const layers: View[] = []
  if (d.kind === "rain" || d.kind === "storm") layers.push(Particles({ preset: "rain", rate: d.kind === "storm" ? 2.5 : d.heavy ? 1.6 : 1 }))
  if (d.kind === "snow") layers.push(Particles({ preset: "snow", rate: d.heavy ? 1.8 : 1 }))
  if (!r.day && (d.kind === "clear" || d.partly)) layers.push(Particles({ preset: "stars", rate: 0.6 }))
  if (d.kind === "clear") layers.push((r.day ? sun(s) : moon(s)).offset({ x: 300 * s, y: -165 * s }))
  if (d.kind !== "clear" || d.partly) {
    const gray = d.kind === "storm" || d.kind === "rain"
    layers.push(cloud(s * 0.7, gray ? "#C9D1DBB3" : "#FFFFFF99").loop({ effect: "float", period: 6, amount: 1.5 }).offset({ x: -310 * s, y: -170 * s }))
    layers.push(cloud(s, gray ? "#E4E9EFE6" : "#FFFFFFEE").loop({ effect: "float", period: 4, amount: 2 }).offset({ x: 290 * s, y: -150 * s }))
  }
  if (d.kind === "storm") {
    layers.push(Capsule().fill("#FFE066").frame(box(7 * s, 48 * s)).rotation(18).glow({ color: "#FFE066", radius: 18 * s, opacity: 0.9 }).loop({ effect: "pulse", period: 1.1, amount: 3 }).offset({ x: 290 * s, y: -82 * s }))
  }
  return layers
}
