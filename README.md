# AuctionatorSync

Auctionator companion addon for WoW Forever. Synchronises auction house price data between players and adds a standalone Price List browser.

Requires [Auctionator](https://www.curseforge.com/wow/addons/auctionator). Auctionator's files are not modified.

## Features

### Price syncing
- Automatic price syncing between all players running AuctionatorSync on the same auction house
- Shared master price list: the newest observed price per item is kept
- Sync on login: handshake with an automatically selected host, exchanging only differing prices (256-section fingerprint comparison)
- Sync after every completed Auctionator scan and after auction house searches
- Discovery through guild, friends list, Battle.net friends and a hidden addon channel
- Hidden addon messages only; no chat output to other players
- Automatic re-sync if a player's price list drifts from the master list

### Price List (`/ah`)
- Browse all synced prices away from the auction house
- Columns: Price, Name, Available, Last seen; sortable
- Category and subcategory sidebar
- Name search, with shift-click item insertion
- Filters: level range, usable only, uncollected only, rarity
- Item tooltips, quality colours, aligned gold / silver / copper

### Settings window (`/async`)
- Online player table: name, version, sync status, last sync time; sortable and filterable, colour coded
- Host indicator
- Price check item for comparing prices between players
- Manual sync, verbose sync log, chat message and minimap options

### Access
- Slash commands: `/async`, `/ah`, `/async sync`, `/async status`, `/async log`
- Minimap button (left-click: settings, right-click: Price List)
- Key binding (Keybindings > AddOns > AuctionatorSync)
- Options > AddOns > AuctionatorSync
- Windows dock beside each other and move as a group (Alt-drag to undock)
