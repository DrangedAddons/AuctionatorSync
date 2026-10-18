# AuctionatorSync

A companion addon for [Auctionator](https://www.curseforge.com/wow/addons/auctionator) on WoW Forever. When someone in your group of friends scans the auction house, everyone else running AuctionatorSync gets the same prices, so you all see the same price on the same item.

## Who it syncs with
- Your **guild**
- Your in-game **friends list**
- Your **Battle.net friends** playing on the same realm

Everyone needs AuctionatorSync installed (plus Auctionator). Prices only sync between characters on the same realm and faction, because Auctionator keeps a separate price list for each of those.

## How it works
- Prices that changed in your scans are collected and sent to everyone online with the addon as one update every few minutes. A rescan that finds the same prices sends nothing.
- A friend's price only replaces yours when it's newer and different.
- When you log in, it asks who has prices that changed since your last catch-up and fetches them from the friend with the most.
- Every price carries the time it was seen, and the newest one always wins.
- Auctionator's own files are never touched. AuctionatorSync watches Auctionator saving prices from outside and writes friends' prices into the same price table a scan fills.

## Commands
- `/async` opens the window: settings, **Sync now**, and who's online with the addon
- `/async sync` catches up now
- `/async status` prints what the addon knows
- `/async debug` toggles debug messages

Untick **Show chat messages** in `/async` to hide the sign-in and sync messages. Replies to commands still show.
