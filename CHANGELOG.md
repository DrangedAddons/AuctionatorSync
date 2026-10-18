# Changelog

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
