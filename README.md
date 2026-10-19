# AuctionatorSync

A companion addon for [Auctionator](https://www.curseforge.com/wow/addons/auctionator) on WoW Forever. When someone in your group of friends scans the auction house, everyone else running AuctionatorSync gets the same prices, so you all see the same price on the same item.

## Who it syncs with
- Your **guild**
- Your in-game **friends list**
- Your **Battle.net friends** playing on the same realm

Everyone needs AuctionatorSync installed (plus Auctionator). Prices only sync between characters on the same realm and faction, because Auctionator keeps a separate price list for each of those.

## How it works
- **When you log in**, the addon picks a host automatically: whoever online has been on longest. You and the host compare prices item by item. Whichever of you saw an item more recently wins, and each of you gets the other's newer prices. The host then passes the new prices you brought on to everyone else online. Everyone online ends up with the newest prices any of you has seen.
- **While you're online with friends**, the prices your scans change are sent to everyone every few minutes. A rescan that finds the same prices sends nothing.
- **If you're alone**, nothing happens. Your prices go into the compare the next time you're online with someone.
- A friend's price only replaces yours when it's newer and different. Only the last 7 days of prices are exchanged.
- Everything travels as hidden addon data, never chat. The only chat line is your own optional summary.
- Auctionator's own files are never touched. AuctionatorSync watches Auctionator saving prices from outside and writes friends' prices into the same price table a scan fills.

## Commands
- `/async` opens the window: settings, **Sync now**, and who's online with the addon
- `/async sync` catches up now
- `/async status` prints what the addon knows
- `/async log` opens the log (tick **Verbose mode** in `/async` to record every step)

Untick **Show chat messages** in `/async` to hide the sign-in and sync messages. Replies to commands still show.
