# AuctionatorSync

A companion addon for [Auctionator](https://www.curseforge.com/wow/addons/auctionator) on WoW Forever. When someone in your group of friends scans the auction house, everyone else running AuctionatorSync gets the same prices, so you all see the same price on the same item.

## Who it syncs with
Everyone online with AuctionatorSync on your realm and faction (Auctionator keeps a separate price list for each). They're found through your guild, your friends list, your Battle.net friends and a hidden AuctionatorSync channel. Everyone needs AuctionatorSync installed (plus Auctionator).

## How it works
Everyone's prices merge into one **master list**, keeping the newest price for each item. Two things start a sync:
1. **Someone comes online.** The addon picks a **host** automatically, from the players already in sync (whoever's been online longest). The newcomer and the host compare fingerprints of their price lists in 256 sections, and swap prices only for the sections that differ. The host merges them into the new master list, sends the newcomer what it was missing, and shares what the newcomer brought with everyone else online.
2. **Your Auctionator prices change.** When a full scan finishes, or you close the auction house after searching, the prices that changed go to everyone online.

If you're alone, nothing happens. Your prices go into your next handshake.

Safety net: if your prices differ from the host's for 2 minutes (for example, two people logged in at once), the addon quietly handshakes with the host again.

A friend's price only replaces yours when it's newer. Everything travels as hidden addon data, never chat; the only chat line is your own optional summary. Auctionator's own files are never touched: AuctionatorSync watches Auctionator saving prices from outside, and writes friends' prices into the same price table a scan fills.

## The /async window
- Settings, **Sync now**, the **Log** button, and a **price check** item (the latest price change, to compare with a friend).
- **Online with AuctionatorSync:** everyone online, with their version and where they stand. The host (marked with a star) holds the master list. **in sync** means the same master list as the host; **handshaking** / **waiting to sync** means they're getting it; **not in sync yet** means different prices for now; **needs update** means an older version that can't sync.

## Commands
- `/async` opens the window
- `/async sync` syncs now
- `/async status` prints the same overview in chat
- `/async prices` opens the Price List: every price in the master list, by category, searchable and sortable, without being at the auction house
- `/async log` opens the log (tick **Verbose mode** in `/async` to record every step, with player names)

Untick **Show chat messages** in `/async` to hide the sign-in and sync messages. Replies to commands still show.
