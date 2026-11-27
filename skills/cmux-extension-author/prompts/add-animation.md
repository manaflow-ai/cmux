# Prompt: add an animation

Motion in a view of your own: `.animation`, `.transition`, `.loop` and `Particles`, declared in
the scene and run by cmux's renderer (they go instant under Reduce Motion). Surface: `section`
(`cmux customize docs section`); the same modifiers work in every view.

<!-- prompt-check: shows "Celebrate" -->

```text
Add a sidebar section called "Streak" to cmux with motion: a big number (start at 3) that rolls
to its new value when it changes, a "Celebrate" button that adds one to it and fires a confetti
burst, and a small star that pulses gently next to the number.

Do it as a cmux extension in this folder (it may be empty):
1. Run `cmux customize docs section` and read it whole, motion part included. It is the
   reference for a sidebar section with a working example; start from that example.
2. Keep the number in a `signal`. Animate with the kit's motion only: `.animation("bouncy")` on
   what changes, `.contentTransition("numericText")` on the number, `.loop({ effect: "pulse" })`
   on the star, and `Particles({ preset: "confetti", burst })` where `burst` is a signal the
   button raises. No timers that redraw.
3. Run `cmux ext dev --once --json`. If it exits 3 (no cmux running), run
   `cmux ext dev --once --headless --json` instead. Fix every error it prints and run it again
   until it exits 0 and its "scene" shows "Celebrate".
Then tell me in two sentences what you made and where I see it.
```
