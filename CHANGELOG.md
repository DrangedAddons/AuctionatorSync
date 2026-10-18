# Changelog

## 0.1.0
First version.
- Shares Auctionator prices with your **guild**, **friends list** and **Battle.net friends** on the same realm and faction who also run AuctionatorSync.
- **Your scans go out automatically:** a few seconds after a scan finishes, the prices it found are sent to everyone online with the addon.
- **Catch up on login:** when you log in, the addon asks who has prices you missed, picks the friend with the most, and fetches them (only prices from the last 7 days).
- **The newest price wins.** AuctionatorSync times every price, so an older price never replaces a newer one. Friends' prices also go into Auctionator's day-by-day history on the day they were seen.
- Works alongside Auctionator without changing it: it watches Auctionator's price saving from outside and writes into the same price table a scan fills.
- `/async` opens a window with the settings, **Sync now** and who's online with the addon. `/async sync`, `/async status`, `/async debug`.
