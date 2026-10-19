# Changelog

## 0.12.5
- **Last sync** is coloured too: **green** under 10 minutes ago, **yellow** under an hour, **red** under a day, **grey** older or unknown.
- The heading filter lists colour their choices to match (Up to date / In sync green, Old / Not in sync red).

## 0.12.4
- Status uses the same colours as Version: **green** in sync, **yellow** handshaking or waiting to sync, **red** not in sync yet, **grey** needs update.

## 0.12.3
- Version numbers in the online list are coloured against the newest version anyone online runs: **green** the newest, **yellow** the same release with an older patch (0.12.1 when 0.12.2 is out), **red** an older release that still syncs (0.11.x), **grey** too old to sync at all.

## 0.12.2
- **Filters moved into the column headings; the Show dropdown is gone.** Click a heading to sort (again to reverse), as before. **Version** and **Status** also have a small arrow next to the name that opens a filter: Version - All / Up to date / Old (older than the newest version anyone online runs); Status - All / In sync / Not in sync. Each choice shows how many players it matches, with a tick on the current one. While a filter is on, the heading shows it in blue ("Old", "Not in sync"); both filters can be on at once.
- The host is always pinned to the top of the list, whichever column you sort by.

## 0.12.1
- The online list's filter is a dropdown: "Show: All" with an arrow; click it for All / In sync / Not in sync / Needs update, each with how many players it shows, and a tick by the current one. Clicking anywhere else closes it.

## 0.12.0
- **The online list is a table:** Player, Version, Status and **Last sync** columns, with column headings over a gold line and striped rows. The host has a crown (like a group leader's). Hover a row for the full status, version and the exact last-sync time.
- **Last sync** per player: when they last finished a handshake (either side), received prices from a sync, or shared their own scan, shown as "just now", "5m ago", "2h ago". Players share it with each other, so everyone sees everyone's.
- **Sort:** click a column heading to sort by it, and click again to reverse; an arrow marks the active one. Sorting by Status keeps the host first.
- **Filter:** the **Show:** button cycles through All, In sync, Not in sync and Needs update.
- `/async status` adds each player's last sync time. The window is a little wider to fit the new column.

## 0.11.1
- The online list, `/async status` and the log use the character's own name instead of "You" / "you" ("Confuciussay is handshaking with Lexi Ble (host)", "Lexi Ble received 340 prices from Fred Dingo; 40 newer than Lexi Ble's"). The price check says "From <name>'s scan".

## 0.11.0
**Sync redone around a master list.** Everyone needs 0.11.0; older versions show as "needs update" and can't sync.
- **Everyone with AuctionatorSync syncs.** The guild / friends list / Battle.net options are gone: players are found through your guild, friends list, Battle.net friends and a hidden AuctionatorSync channel (kept out of your chat windows), and nobody is filtered out. Before, a whisper from a friend was ignored unless *you* also had *them* on your friends list, which is why friends and Battle.net friends often never synced.
- **A fingerprint of everyone's prices.** Each player's price list has a fingerprint (256 section sums). Equal fingerprints mean the same master list, so "in sync" is something the addon knows, not a guess.
- **Two triggers:**
  1. Someone comes online: they handshake with the host (picked automatically from players already in sync, online longest). Only the sections whose fingerprints differ are exchanged, so logging in when nothing changed sends almost nothing. The host merges the newest prices into the master list, sends the newcomer what it was missing, and shares what the newcomer brought with everyone else.
  2. Your Auctionator prices change: when a full scan finishes, or you close the auction house after searching, the changed prices go to everyone online. This replaces the 1-minute share timer.
- **Safety net:** if your prices differ from the host's for 2 minutes (say two people logged in at once), you quietly handshake with the host again.
- **Online list redone:** everyone online, you included, with their version and status: **in sync**, **handshaking with ...**, **waiting to sync**, **not in sync yet** or **needs update**. The host is first, marked with a star and "host". The header shows how many are in sync; click it to fold the list into one summary line.
- **Detailed log (Verbose mode), with player names:** who came online or went offline, who is handshaking with whom, which sections differed, how many prices were sent and received, "new master list generated", "master list ready: sharing ... with N other players", who is now in sync, scans starting and finishing, and what your scans shared.
- Same-time ties (two different prices seen in the same second) go to the lower price on every player, so everyone ends up identical.
- `/async status` prints the same overview: your fingerprint and every player's status.
- All prices count now; the 7-day limit on synced prices is gone.

## 0.10.1
- The realm and last-sync text in `/async` no longer runs under the new Log button.

## 0.10.0
- **Verbose mode and log window.** Tick **Verbose mode** in `/async` (off by default) and a log window opens showing what AuctionatorSync is doing, step by step and timestamped: Auctionator scans starting and finishing, changed prices shared or kept for later, every hidden message sent (>>) and received (<<), who answered at login, which host was picked and why, how many prices were uploaded, received and changed, what a host sent back and passed on, and anything ignored (another realm or faction, someone not in your guild or friends list).
- The log keeps the last 500 lines, even across `/reload`, so you can look back at what happened. **Clear** empties it; scroll with the mouse wheel (Shift jumps to the top or bottom); drag the corner to resize. Only you can see it.
- Open it any time with the **Log** button in `/async` or `/async log`. It only records while Verbose mode is ticked.
- `/async debug` now opens the log too (the old debug chat lines are gone).

## 0.9.0
**New way of syncing at login: compare with a host.** Everyone needs 0.9.0; older versions can't act as host.
- When you log in, the addon picks a host automatically: whoever online has been on longest, preferring people who've finished their own sync. You never pick anything yourself.
- You and the host compare prices item by item. For each item, whichever of you saw it more recently wins. You get every price where the host's is newer or you don't have it, and the host gets every price where yours is newer.
- The host then passes the new prices you brought on to everyone else online. Everyone online ends up with the newest prices any of you has seen, and that combined data travels on to whoever logs in next. Prices from a group of friends you were never online with now reach everyone too, carried along by whoever overlaps both groups.
- If the host logs off or goes quiet partway through, the addon moves on to the next person.
- Alone, nothing happens. Your prices simply go into the compare the next time you're online with someone.
- Replaces the old one-way catch-up, which only pulled toward whoever logged in, from just one friend, and could skip data from friends you'd never been online with.
- Everything still travels as hidden addon data, never chat. The chat line reads "Synced: updated N prices." or "Up to date.", and you can turn it off.
- Live sharing of your new scans to friends online is unchanged.

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
