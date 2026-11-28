title: Agent posts and emails send exactly the approved draft
category: fixed

When an agent posts on X or LinkedIn or sends a Gmail message through cmux's site helpers, cmux now checks that the composer holds the whole approved draft before it presses Post or Send. Before, it checked only the first 40 characters, so a draft whose end was changed could still be sent. On a mismatch nothing is sent, and the error says where the composer and the draft differ.
