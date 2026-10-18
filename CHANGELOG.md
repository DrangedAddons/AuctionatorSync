# Changelog

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
