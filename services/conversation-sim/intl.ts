// The "intl" conversation: friends who write in Spanish, Japanese and French,
// for exercising Translate. Seeded on its own stream, so the group and direct
// histories are byte-for-byte unchanged by its existence.
import { pick, randInt, type Rng } from "./corpus";

export const INTL_PEOPLE = [
  { id: "sofia", name: "Sofía García", initials: "SG", colorHex: "#FF453A", isMe: false, lang: "es" },
  { id: "haruto", name: "Haruto Sato", initials: "HS", colorHex: "#64D2FF", isMe: false, lang: "ja" },
  { id: "camille", name: "Camille Martin", initials: "CM", colorHex: "#FFD60A", isMe: false, lang: "fr" },
] as const;

const LINES: Record<string, readonly string[]> = {
  es: [
    "¡Hola! ¿Cómo va todo por allá?",
    "Acabo de probar la nueva versión y el desplazamiento se siente mucho más fluido.",
    "¿Nos vemos mañana para revisar el diseño?",
    "Perdón por la demora, estuve en una reunión toda la tarde.",
    "Me encanta cómo quedaron las burbujas de los mensajes.",
    "¿Alguien sabe por qué falla la compilación nocturna?",
    "Voy a preparar café, ¿quieren algo?",
    "Gracias por la ayuda de ayer, de verdad me salvaste.",
    "El vuelo sale a las ocho, así que llego tarde a la llamada.",
    "Creo que el problema está en cómo se reconecta el socket después de dormir.",
    "¡Qué buena noticia! Felicidades al equipo.",
    "Mañana hace sol, podríamos trabajar desde el parque.",
    "No encuentro el enlace al documento, ¿me lo pasas?",
    "Ya subí los cambios, avísame si ves algo raro.",
  ],
  ja: [
    "おはようございます！今日もよろしくお願いします。",
    "新しいビルドを試してみました。スクロールがとても滑らかです。",
    "明日の打ち合わせは何時からですか？",
    "すみません、少し遅れます。電車が止まっています。",
    "このバグは再接続のタイミングが原因だと思います。",
    "ランチに行きませんか？駅前の新しいラーメン屋が気になっています。",
    "資料を共有しました。確認してもらえると助かります。",
    "週末は京都に行ってきました。紅葉がとてもきれいでした。",
    "ありがとうございます！とても助かりました。",
    "テストが全部通りました。マージしても大丈夫だと思います。",
    "今夜のリリースは延期になりそうです。",
    "その件については後で詳しく説明しますね。",
  ],
  fr: [
    "Salut tout le monde ! Vous avez passé un bon week-end ?",
    "J'ai testé la dernière version, les animations sont vraiment réussies.",
    "On peut décaler la réunion à quinze heures ?",
    "Je pense que le problème vient du cache des images.",
    "Merci beaucoup pour ton aide, c'était parfait.",
    "Il pleut encore à Paris, quelle surprise.",
    "Quelqu'un a le lien vers la maquette ?",
    "Je viens de pousser un correctif, dites-moi si ça marche chez vous.",
    "Bon appétit ! Je reviens dans une heure.",
    "La compilation de nuit a encore échoué, je regarde ça.",
    "C'est une excellente idée, allons-y.",
    "Je serai en vacances la semaine prochaine.",
  ],
};

const MINE = [
  "sounds good!",
  "thanks, I'll take a look",
  "haha yes",
  "can you send the link?",
  "running a bit late, sorry",
  "nice work 🎉",
  "I'll be there at 3",
  "let me check and get back to you",
];

/** A line in `senderId`'s language (mine are English). */
export function intlText(rng: Rng, senderId: string): string {
  const person = INTL_PEOPLE.find((p) => p.id === senderId);
  return person ? pick(rng, LINES[person.lang]) : pick(rng, MINE);
}

/** Seeded history: a few days of short sessions, ending a few minutes ago. */
export function intlHistory(rng: Rng, count: number, meId: string): { senderId: string; sentAt: number; text: string }[] {
  const out: { senderId: string; sentAt: number; text: string }[] = [];
  const now = Date.now();
  let t = now - 4 * 86_400_000;
  for (let i = 0; i < count; i++) {
    // Mostly a minute or two apart, with a long gap every dozen or so.
    t += rng() < 0.08 ? randInt(rng, 3, 14) * 3_600_000 : randInt(rng, 20, 240) * 1000;
    const senderId = rng() < 0.25 ? meId : pick(rng, INTL_PEOPLE).id;
    out.push({ senderId, sentAt: t, text: intlText(rng, senderId) });
  }
  // Compress so the newest message is a few minutes old.
  const shift = out.length ? Math.max(0, out[out.length - 1].sentAt - (now - 300_000)) : 0;
  for (const m of out) m.sentAt -= shift;
  return out;
}
