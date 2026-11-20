# Chungus

A World of Warcraft addon suite that, to a first approximation, wrote itself.

> **Honest disclaimer, up front.**
> About seven lines in every ten here were produced by a language model that I
> prompted, squinted at, and occasionally yelled at. The other three are mine.
> I have not audited the seven. That is the deal. It works, mostly, and
> `/reload` is one keystroke away.
>
> If you find something beautiful, I probably wrote it.
> If you find something cursed, assume it came out of the seven.

## Why this exists

I wanted profile management for my addons and I did not want to spend a weekend
writing `SavedVariables` plumbing by hand. So I described what I wanted, said
"continue" a lot, and shipped the result. The ratio is roughly 30/70 human to
machine, give or take a confidence interval. You are welcome to guess which
functions are which.

## What's in the box

| Addon | What it does | Confidence |
| --- | --- | --- |
| **Chungus** | Profile manager platform and shared core for all `Chungus*` modules. `/chungus` opens it. | Reasonable |
| **ChungusSetup** | Per-addon profile actions: slash commands, native APIs, savedvar snapshots. | Depends |
| **ChungusChat** | Placeholder module. Chat features "to come". Very much to come. | Aspirational |

All three are `Interface: 16001` and the two satellites depend on `Chungus`.

## Install

1. Copy the `Chungus`, `ChungusChat`, and `ChungusSetup` folders into
   `Interface/AddOns/`.
2. Restart the client (or `/reload` if the addons are already loaded).
3. Type `/chungus`.

That's it. There is no installer, no dependency manager, and no onboarding
wizard. There is barely a plan.

## Using it

- `/chungus` — open the main window.
- Profiles are per-addon; `ChungusSetup` exposes the actions for each module.
- Saved variables: `ChungusDB` (account) and `ChungusCharDB` (per character).

## Status

Version 2.0.0. Features get added when I feel like it and when the model feels
like cooperating. Bug reports are welcome; please include whether the bug looks
like the work of a careful human or the work of the other seven-tenths.

## Lineage

Generated in collaboration with an AI, reviewed by a human with limited patience.
If you contribute, you may use whatever tools you like — I certainly did.

## License

Do what you want with it. Attribution optional. Understanding optional.
