# Changelog

## 0.8.0
- **Your scans reach friends even if nobody was online when you scanned.** Changed prices that couldn't be sent now wait in a queue, kept across logouts, instead of being dropped. As soon as anyone with AuctionatorSync comes online, whether they log in while you're on or you log in while they're on, the queue goes out a few seconds later (one guild message covers the whole guild). Before, a catch-up only ever pulled prices toward whoever had just logged in, so your scan could miss friends who were online before you.
- An item a friend has since updated with a newer price is dropped from your queue; an item whose price went back to what you last sent is skipped.
- Updates are only sent to people who are still online, so you no longer see "No player named ... is currently playing." for friends who logged off.

## 0.7.2
- New icon: a bronze gavel on its sound block with a blue sync badge (two circling arrows) in the corner, replacing the goblin auctioneer. Original artwork, in the spirit of Auctionator's gavel.

## 0.7.1
- New icon: a goblin auctioneer behind his podium, gavel raised. Shown in the game's AddOns list and in the DrangedAddons manager.

## 0.7.0
- **Online list grouped by version.** The `/async` window shows everyone online with AuctionatorSync, you included, as one compact line of counts per version ("v0.7.0 ×3   v0.6.1 ×1"). Click the header to expand it into names per version, and click again to collapse; the window remembers which you chose. The newest version is green and older ones are orange, so you can see who needs to update. Only people who are actually online are listed, and the window resizes to fit.
- `/async status` lists who's online the same way, grouped by version.
- Fixed: the first `/async` after logging in did nothing, and you had to type it twice.

## 0.6.1
- Messages no longer name who prices came from. Chat says "Updated 37 prices.", "Caught up: updated 812 prices." and "Up to date.", and the price check says "From AuctionatorSync" (or "From your scan").

## 0.6.0
- **Price check in `/async`:** the latest item whose price changed, as an item button with its icon, name, new price (and what it was), and whether it came from your scan or a friend, and when. Hover for the full tooltip, including Auctionator's price lines; Shift-click to link it in chat. If a friend's price for the same item matches, you're in sync.
- **You no longer sync with yourself.** Your own messages could come back to you and be taken for a friend's (you'd see "Catching up ... from <your own name>"). Every message now carries a random per-login ID, and anything carrying your own ID or name is ignored.
- **Accurate catch-ups after a scan** (replaces 0.5.0's "nothing to catch up"). A catch-up still waits for a running scan, then asks a friend for what the scan didn't cover: your request lists the items your scan priced, and the friend skips those it saw before your scan, since yours are newer. Prices for items your scan didn't see (nothing listed at the time) still come through, as does anything newer than your scan.
- Friends who were offline when you scanned get your changes in their next catch-up, as before; friends online get them with the next update.

## 0.5.0
- **No catch-up from friends right after your own scan.** AuctionatorSync now knows when an Auctionator full scan starts and finishes (it listens to Auctionator's own scan events and still changes nothing in Auctionator).
  - While a scan runs, a catch-up waits for it. If it was still asking around, it's called off.
  - When the scan finishes, your prices are the newest, so instead of fetching prices you'd only throw away you get one line: "Your scan is the newest, so there's nothing to catch up."
  - Later catch-ups only ask friends for prices they saw *after* your last full scan, so anything your scan already covers isn't sent.

## 0.4.0
- **Sign-in message:** a few seconds after you're in the world, one line says the addon is ready, who it syncs with and that `/async` has the options. A few seconds later, one more line gives the catch-up result: "Up to date with Bob and Alice.", "Caught up: updated 812 prices from Bob." or "No one online with AuctionatorSync yet."
- **Shorter, clearer chat.** Updates from friends are one line: "Updated 37 prices from Bob." Updates from several friends arriving together share one line ("Updated 52 prices from Bob, Alice and 2 others."). Nothing is said when nothing changed, and sending is never announced. Big numbers get thousands separators.
- **Show chat messages** box in `/async` (on by default): untick it to hide the sign-in and sync messages. Replies to `/async` commands and **Sync now** still show, since you asked for them.
- `/async status` reads as three short lines; `/async help` is one line.

## 0.3.0
- **Changes go out on a timer.** Your scans' changed prices are collected and sent as one update every minute (every 5 minutes once we go live), not straight after each scan. An item that changes several times in that window is sent once, with its newest price; one that goes back to the price it had at the last update isn't sent at all. **Sync now** sends what's collected straight away.
- **Only different prices are written.** A friend's price only goes into your Auctionator data when it's newer *and* different from yours. A newer sighting of the same price just updates AuctionatorSync's own timestamp, and an older price is never written.
- **One chat line per sync, with the total:** "Synced 4213 changed prices from Bob (6000 checked)." Big syncs still travel in batches of 1500, but you only hear about it once the last batch is in.

## 0.2.0
- **Only changed prices are sent.** AuctionatorSync now remembers each item's price before a scan, so a rescan that finds the same price sends nothing. Catch-ups only carry prices that changed since your last catch-up, not every price seen since then.
- A newer sighting of the same price still updates the item's timestamp (so the freshest sighting keeps winning), but it isn't counted or announced.
- **One chat line per transfer:** "N changed prices from Bob." when the last batch arrives, instead of a line for every batch of 1500. Only real changes are counted.
- After a catch-up, if the friend you caught up from sent prices that are older than yours and different, your newer ones go back to them, so you both end up with the same prices.

## 0.1.0
First version.
- Shares Auctionator prices with your **guild**, **friends list** and **Battle.net friends** on the same realm and faction who also run AuctionatorSync.
- **Your scans go out automatically:** a few seconds after a scan finishes, the prices it found are sent to everyone online with the addon.
- **Catch up on login:** when you log in, the addon asks who has prices you missed, picks the friend with the most, and fetches them (only prices from the last 7 days).
- **The newest price wins.** AuctionatorSync times every price, so an older price never replaces a newer one. Friends' prices also go into Auctionator's day-by-day history on the day they were seen.
- Works alongside Auctionator without changing it: it watches Auctionator's price saving from outside and writes into the same price table a scan fills.
- `/async` opens a window with the settings, **Sync now** and who's online with the addon. `/async sync`, `/async status`, `/async debug`.
