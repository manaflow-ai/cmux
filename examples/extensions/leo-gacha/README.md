# Chief gacha

Press Pull: a card shakes, pops open and reveals a Chief, glowing in its rarity's color, with a
burst of sparkles (confetti for epic and legendary). The collection log keeps every Chief you
pulled, how many times and since when; the ones you are missing show as silhouettes. An agent
finishing a turn gives you a free pull. A pane is the stage; a sidebar section shows your latest.

```sh
cmux ext dev examples/extensions/leo-gacha
```

Edit `src/chiefs.ts` for the Chiefs and their odds, `src/main.ts` for the cards. Settings > Apps >
Chief gacha picks the card style (`holo`, `pixel`, `glass`) and turns the agent pulls off. All
motion is declared (`.loop`, `.transition`, `.animation`, `.glow`, `Particles`) and run by cmux.
