# Plans and credits

What is free, what costs money, and how cmux credits work.

> Paid plans for cmux-next are in preview and not on sale yet. Prices and limits can change before launch. This page says how billing works, not what it costs.

## Free

- The app, the CLI, terminals, browser tabs, remote machines, and Home are free.
- Agents that use your own Claude Code or Codex sign-in, or your own API key, are free. cmux does not meter them or see their bill.

## cmux credits

cmux credits pay for what cmux runs for you: models through cmux inference, and cloud machine time. One credit is one US dollar. Buy credits in the app; they work with or without a plan.

When an agent's model needs a key you do not have, the chat shows a card with three choices: add your own API key, use cmux credits, or add credits.

## Plans

A paid plan adds included credits each month, more cloud machines at once, and larger machines. Team plans pool the included credits of all seats. Use above the included amount is charged at cost or taken from prepaid credits.

## See your usage

Open the command palette and run Chief Usage, or Upgrade to cmux Pro to see the plans. Your accounts and sign-ins are in Accounts:

```bash
cmux accounts show
```

- [Cloud machines](cloud.md)
- [Run agents on your own API keys](own-keys.md)
- [Audit agent spend](agent-spend.md)
