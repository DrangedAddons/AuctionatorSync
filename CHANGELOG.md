# Changelog

## 0.19.1
- **Less status chatter during transfers, so handshakes get more of the bandwidth.** Progress-only status updates (a percentage moving) now go out at most every 10 seconds; real changes (starting or finishing a sync, a new fingerprint, hosting) still go out within 2 seconds. Before, a transfer sent a status update every 2 seconds, which used up a large share of the game's limited allowance for addon messages.
- Status updates go on the hidden channel only when someone online can't be reached through the guild, instead of on both every time. Logins still look everywhere.
- (The log itself never sends anything: it's only on your own screen.)

## 0.19.0
- **Stalled handshakes are dropped and moved on.** A handshake piece is only kept alive while prices are actually moving (our upload batches going out or the host's reply batches arriving). Before, any message from the host, even its once-a-minute heartbeat, kept a stuck piece alive forever. If nothing moves for 60 seconds:
  - the host is told to stop (it stops sending that piece and stops hosting it),
  - our upload to it stops,
  - the piece goes to another in-sync host and starts again,
  - and the stalled host is **benched for 10 minutes**: it isn't picked as a host for any handshake until then. A host that doesn't answer the compare step within 45 seconds is benched the same way.
  - With no other host free, the handshake stops cleanly and tries again later.
- **Sync Monitor:** the activity is split into **Activity** (what they're doing: "Handshaking: sending", "Receiving", "Sharing", "Hosting") and **Amount** (its x / y, e.g. "1,500 / 4,000"), for everyone's rows. Benched hosts are listed at the bottom with the time they have left.

## 0.18.1
- Fixed handshakes getting stuck on "comparing". If a player reloaded mid-handshake (e.g. to update), their host kept sending them the whole old reply, minutes of data they'd throw away, and the new handshake's small "which sections differ" answer queued behind it.
  - Transfers now go out one batch at a time (the next batch is only queued once the last has actually been sent), so they can be stopped midway.
  - When a player reloads (a new login session) or goes offline, everything still unsent to them is dropped, along with any handshake piece being hosted for them. The log notes it.
- The compare step gives up on a host after 45 seconds (it was 3 minutes) and compares with another in-sync player instead.
- The compare step names who it's waiting for: "comparing - waiting for Confuciussay Dranged".

## 0.18.0
- **Much faster handshakes for returning players.** A login handshake now only moves prices that can actually be new: the newcomer sends the prices it has seen since its last sync (at which point its list matched the master list), and the host sends back the prices it has seen since then plus any that differ from what the newcomer sent. Before, any section with a single different price was exchanged in full both ways, which after a scan meant nearly the whole price list (minutes, given the game's limit on addon messages). Someone who synced yesterday and hasn't scanned since now moves a few hundred prices instead of thousands.
- If a quick handshake ever leaves someone not matching the master list (say they last synced with a different group), the self-repair runs a **full** handshake. A first-ever sync is always full. The log says which kind each handshake is.
- "Last sync" only moves on once a handshake really ends matching the master list.
- Item numbers are sent as numbers rather than text: about 15% less data.

## 0.17.2
- **Handshake progress covers the whole handshake**, not just the last step: comparing, then sending your prices to the hosts, then receiving theirs, weighted by how many prices each moves. The step shows next to the percentage: "handshaking with Lexi Ble +2 - sending 1,500 / 4,000 (31%)" in the online table, and "Handshaking: sending 1,500 / 4,000" in the Sync Monitor (other players see it too).
- The log covers the comparing step: when the section sums have actually gone out, and how many sections the host says differ.
- The Sync Monitor is a little wider to fit.

## 0.17.1
- The Sync Monitor has its own buttons instead of opening with the log: **Monitor** in `/async` (next to Log) and **Sync Monitor** at the top of the log window. Opened from the log while the settings window is closed, it docks to the log. Also `/async monitor`.
- The `/async` buttons are a little narrower to make room.

## 0.17.0
- **Sync Monitor:** a torrent-client style window that opens alongside the log (and closes with it), docked beside it.
  - Top line: the master list (short fingerprint), how many prices this character has, when the newest price was seen, and how many are online.
  - One row per player who is doing something right now: **Activity** (handshaking, looking for hosts, receiving, sharing, hosting, or a mix), a **Progress** bar, **Hosts** (how many hosts their handshake is pulling from), **Hosting** (how many handshakes they're serving) and **Syncing to** (the master list version they're catching up with).
  - **Transfers on this character:** each handshake piece (host, sections, prices so far) and each batch transfer in or out, with progress and a time-left estimate.
  - Everyone else is compacted underneath: **In sync**, **Not in sync yet**, and **Can't sync (old version)**.
- Players share a little more in their status (hosts in use, target master list, receive and send progress) so their rows can show it. Everyone needs 0.17.0 for other players' rows to fill in fully.

## 0.16.2
- **Whoever just scanned is in sync.** The master list is now the version holding the newest price (equally new: the one most players hold), so after a scan the scanner leads and shows "in sync", instead of being outvoted until the others caught up. Before, a long share could even make the scanner "re-sync" back to the older list.
- New status **receiving updates** (yellow): a player whose prices are still arriving shows this instead of "not in sync yet"; the self-repair also waits while prices are arriving.
- **Progress in the log:** big transfers log every batch on both ends: "Grove -> everyone: sent 1,000 / 1,876 prices (scan prices, 53%)" once a batch has actually gone out, and "Fred Dingo <- Grove: 1,000 / 1,876 prices (scan prices, 53%)" as it arrives. This covers scan shares, handshake pieces and replies, and share-outs.
- Prices travel in batches of 500 instead of 1,500, so progress moves in finer steps.

## 0.16.1
- The number of hosts a big sync uses now adapts: at most half of the in-sync players who aren't hosting anyone (so others logging in at the same time still find a free one), at least 16 sections per host, and never more than 6. Small groups end up much as before; busy guilds can spread a big sync wider.

## 0.16.0
**Protocol 4: any in-sync player can host, and big syncs pull from several hosts at once.** Everyone needs 0.16.0; older versions show as "needs update".
- **No single host any more.** Anyone who holds the master list can host a handshake. A newcomer picks the least busy one (Battle.net friends first among equals, then at random), so people logging in together spread out instead of queueing behind one player. Each finished player becomes another possible host.
- **Swarming:** when more than 16 of the 256 sections differ (a first sync, or someone back after a while), the sections are split across up to 4 in-sync hosts at once, each merging and sending back its share. The game limits how fast each player can send, so several senders make big syncs up to about 4x faster. If a host goes quiet, its share moves to another.
- **The master list is the fingerprint most ready players hold** (ties: the one with the newer newest price). Each player now also shares the time of their newest price. When two versions of the list meet, they're merged by the next handshake (the 2-minute self-repair), and nothing is lost, because merging is newest-wins per item in any order.
- **Online table:** "handshaking with Lexi Ble +2 (61%)" shows progress; "in sync - hosting 2" shows who's serving; the crown marks players hosting right now. Hover a row for that player's newest price time.
- **Log:** who is comparing with whom, how the differing sections were split ("splitting across 3 hosts: Lexi Ble (40), Fred Dingo (40), Grove (39)"), what each host sent, reassignments, and who is hosting.

## 0.15.13
- Descriptions now say when prices are shared: whenever someone views or scans the auction house and discovers new prices.

## 0.15.12
- Shorter, to-the-point descriptions (AddOns list tooltip, Options > AddOns page, README, repository description).

## 0.15.11
- Descriptions rewritten as feature lists (AddOns list tooltip, Options > AddOns page, README, repository description).

## 0.15.10
- Updated descriptions to match what the addon does now (the AddOns list tooltip, the Options > AddOns page, the README and the repository description): the shared, always-newest master price list, silent syncing at login and after scans, and the Price List.

## 0.15.9
- Shift-clicking a bag item into the Price List search no longer also opens the stack split box (Blizzard's or EllesmereUI's). When the Price List isn't the one taking the click, splitting works as normal.

## 0.15.8
- Price List search: a small **x** inside the end of the search box clears it (shown only when there's text), and clicking into the box selects what's there, so you can just start typing to replace it.

## 0.15.7
- Docked windows move as one group: dragging any of them (the Price List, the settings window or the log) moves the whole group together. Hold **Alt** while dragging to take just that window out of the group.

## 0.15.6
- Docked windows stay docked: a window that opened beside another is attached to it, so dragging the Price List (or whichever window it docked to) brings the docked windows along. Dragging a docked window itself detaches it.

## 0.15.5
- Price List: shift-click an item (in your bags, a chat link, anywhere) while the Price List is open and its name goes into the search box, like at the auction house. While you're typing in chat, the link goes to chat as usual.

## 0.15.4
- The Price List's **Settings** button now toggles the `/async` window: click it again to close it.

## 0.15.3
- The three windows (`/async`, the log and the Price List) no longer open on top of each other. One that opens while others are up docks beside them, edge to edge with the tops level: to the left of the first open window if it fits on screen, otherwise to its right, below or above, never overlapping. With nothing else open, a window opens where you last left it.

## 0.15.2
- Fixed: the clear button next to **Filter** was invisible (its icon doesn't exist on Forever). It's now a small **X** button in the same style as Filter and Settings, greyed out when there's nothing to clear.

## 0.15.1
- Price List Filter: nothing is ticked to start, and nothing ticked means no filter. Ticking something turns that filter on; for **Rarity**, ticking qualities shows only those (untick them all and every quality shows again).
- A small red X next to **Filter** clears just the Filter dropdown. The **Clear filters** button above the categories clears everything: category, search and the Filter dropdown.

## 0.15.0
- **Price List Filter**, like the auction house's: a **Filter** button next to the search box opens a panel with **Level Range** (min / max required level), **Uncollected Only** (gear whose appearance this account hasn't collected), **Usable Only** (items this character can use), and **Rarity** (Poor to Legendary, in their colours, all ticked to start). The button reads "Filter *" in blue while any of these are active, and **Clear filters** resets them along with the category and search. Uncollected Only and Usable Only only appear if the game client supports them.
- The name book now also keeps each item's required level (needed for Level Range). Items saved before this version get it added once, behind the usual loading bar.
- **Settings** button at the top right of the Price List opens the `/async` window.

## 0.14.0
- **Minimap button:** left-click opens the settings, right-click the Price List, drag to move. It works with minimap-button collector addons (LibDBIcon). **Show minimap button** in `/async` hides or shows it.
- The addon list button at the top of the minimap opens AuctionatorSync too (left-click settings, right-click Price List).
- **Options > AddOns > AuctionatorSync:** a page with the icon, a short description of what the addon does, and **Open settings** / **Open Price List** buttons.
- Price List: the Price column is wider, so even the gold cap (9,999,999g 99s 99c) fits inside it; the other columns moved over to make room.

## 0.13.5
- Price List: much smoother scrolling. Scrolling now only redraws the visible rows; the filtered, sorted list is kept and only remade when the search, category, sort or prices change (before, every scroll step re-sorted the whole list). Names are lowercased once per item instead of on every comparison, the sidebar keeps its counts between scrolls, and the background refresh only rebuilds when prices have actually changed.

## 0.13.4
- Quick ways to open the Price List: **`/ah`**, and a key binding. Set the key under Options > Keybindings > AddOns > AuctionatorSync ("Open / close the Price List"); there is no default key, so nothing of yours gets overwritten.

## 0.13.3
- Price List: a **Clear filters** button above the categories sets the category back to All and empties the search. It is greyed out while nothing is filtered.

## 0.13.2
- Price List: prices are split into aligned gold, silver and copper parts, so every gold amount lines up under the others, likewise silver and copper. Silver and copper always show two digits (12g 05s 00c); under 1 gold, the gold slot is left empty.

## 0.13.1
- Price List: tidied the top row. The search box lines up with the list, the item count sits at the far right, and the overlapping note is gone (hover the **Available** heading for what that column means).

## 0.13.0
- **Price List:** browse the master list's prices anywhere, without being at the auction house. Open it with the new **Price List** button in `/async` (or `/async prices`).
  - Laid out like the auction house: a category sidebar on the left (**All**, then each category with its item count; click one to show it, and its subcategories open underneath, click again to close them), a **search** box that filters by name as you type, and a list with **Price | Name | Available | Last seen** columns. Click a column to sort, again to reverse.
  - Names in their quality colours, item icons, gear with its item level. Hover an item for its full tooltip (including Auctionator's price lines); Shift-click to link it in chat.
  - Last seen is coloured: green this hour, yellow today, red this week, grey older. Available is the quantity the last scan saw that day.
- **Item names always display properly.** A background warm-up after login quietly asks the game for each item's name and quality, and a saved name book keeps them for next time. If the window is opened before that's finished, it shows a "Loading item details... 1,240 / 1,284" bar instead of half-drawn rows; anything that never loads (an item removed from the game) is left out.
- The text beside **Sync now** shows just the last sync time (the realm is still in `/async status`).

## 0.12.7
- When there's no last-sync time to show for the host, the Last sync column says **host** (in green): the host holds the master list, so it's in sync by definition.
- The log window opens to the left of the `/async` window (its top-right corner against the `/async` window's top-left) instead of underneath it. It can still be dragged anywhere.

## 0.12.6
- **Click a column heading for a dropdown** with its sort choices and, on Version and Status, its filters, each ticked when active: Player - A to Z / Z to A; Version - Newest first / Oldest first, then All / Up to date / Old; Status - In sync first / Not in sync first, then All / In sync / Not in sync; Last sync - Most recent first / Longest ago first. Each heading has a small arrow to show it opens a menu; the sorted column's heading is white, a filtered one shows the filter in blue.
- No more tooltips on the column headings, and the separate filter arrows are gone.

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
