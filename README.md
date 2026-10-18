# AuctionatorSync

A companion addon for [Auctionator](https://www.curseforge.com/wow/addons/auctionator) on WoW Forever. When someone in your group of friends scans the auction house, everyone else running AuctionatorSync gets the same prices, so you all see the same price on the same item.

## Who it syncs with
- Your **guild**
- Your in-game **friends list**
- Your **Battle.net friends** playing on the same realm

Everyone needs AuctionatorSync installed (plus Auctionator). Prices only sync between characters on the same realm and faction, because Auctionator keeps a separate price list for each of those.

## How it works
- After you scan, the new prices are sent to everyone online with the addon.
- When you log in, it asks who has prices you missed and fetches them from the friend with the most.
- Every price carries the time it was seen, and the newest one always wins.
- Auctionator's own files are never touched. AuctionatorSync watches Auctionator saving prices from outside and writes friends' prices into the same price table a scan fills.

## Commands
- `/async` opens the window: settings, **Sync now**, and who's online with the addon
- `/async sync` catches up now
- `/async status` prints what the addon knows
- `/async debug` toggles debug messages
