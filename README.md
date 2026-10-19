# AuctionatorSync

A companion for [Auctionator](https://www.curseforge.com/wow/addons/auctionator) on WoW Forever. Everyone running AuctionatorSync shares one **master price list** that always holds the newest price anyone has seen, and you can browse it anytime in the **Price List**, without being at the auction house.

Requires Auctionator. Auctionator itself is never changed: AuctionatorSync reads and writes the same price data Auctionator's scans fill.

## Price syncing
- **Everyone with the addon syncs.** Players are found through your guild, friends list, Battle.net friends and a hidden AuctionatorSync channel. Prices are shared per auction house, the same way Auctionator stores them.
- **Coming online:** you handshake with a **host**, picked automatically from the players already in sync (whoever's been online longest). You compare fingerprints of your price lists, swap only the prices that differ, and the host shares anything new you brought with everyone else.
- **Scanning:** when an Auctionator scan finishes (or you close the auction house after searching), the prices that changed go to everyone online.
- **The newest price always wins.** Unchanged prices aren't sent, and older ones never overwrite newer ones.
- It runs silently: everything travels as hidden addon data, never chat. The only chat line is your own optional summary.

## The Price List (`/ah`)
- Every price in the master list, laid out like the auction house: **Price**, **Name**, **Available** and **Last seen** columns. Click a heading to sort.
- A category sidebar (All, then each category and its subcategories), a search box, and a **Filter** panel: level range, usable only, uncollected only, and rarity.
- Item names and quality colours, aligned gold / silver / copper, item tooltips (including Auctionator's own price lines). Shift-click items into the search box or into chat.

## The settings window (`/async`)
- Options, **Sync now**, and buttons for the Price List and the log.
- **Online with AuctionatorSync:** a table of everyone online, with their version, status (in sync, handshaking, waiting to sync, not in sync yet, needs update) and last sync time, all colour coded. The host has a crown. Click a heading to sort or filter.
- A **price check** item (the latest price change) to compare with a friend.
- **Verbose mode** opens a log of every sync step, with player names.

## Getting to it
- `/async` for settings, `/ah` for the Price List, `/async status` for a summary in chat, `/async log` for the log
- The **minimap button**: left-click for settings, right-click for the Price List
- A key binding under **Keybindings > AddOns > AuctionatorSync**
- **Options > AddOns > AuctionatorSync**

The windows dock beside each other without overlapping and drag as a group (Alt-drag undocks one).
