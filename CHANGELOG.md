# Changelog

## Refactor

- **Reduced Cache Reliance:** Major refactoring to reduce the library's dependency on caching. The bot will now work more reliably in uncached guilds and channels.
    - `client:getGuild(id)` now fetches the guild from the API if it's not in the cache.
    - `client:getChannel(id)` now fetches the channel from the API if it's not in the cache.
    - `guild:getMember(id)` now always fetches the member from the API on a cache miss.
- **Centralized Data Access:**
    - Moved role and emoji fetching logic to the `Client` class.
    - `client:getRole(id)` now iterates through cached guilds to find a role.
    - `client:getEmoji(id)` now iterates through cached guilds to find an emoji.

## Events

- **Improved Event Handling:** Event handlers are now more robust and can handle events from uncached guilds.
- **New Events:**
    - `emojisUpdate` - fired when a guild's emojis are updated.
    - `guild:fetch()` - fetches the full guild data from the API and updates the guild object's properties..
- **Removed Events/Functions:**
    - Removed internal `GUILD_MEMBERS_CHUNK` and `GUILD_SYNC` logic that was tied to the old caching system.
