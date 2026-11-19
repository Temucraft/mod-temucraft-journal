# mod-temucraft-journal

A dungeon journal for 3.3.5: every dungeon and raid, its bosses, and what each boss drops per difficulty. The
journal is a client addon (`client/AddOns/TemucraftJournal`); its data is written by the server, so custom bosses
and loot are in it.

1. On the server (in game or the console): `.journal export`. It writes [`TemucraftJournal_Data.lua`](https://github.com/Temucraft/mod-temucraft-journal/blob/master/client/AddOns/TemucraftJournal/TemucraftJournal_Data.lua)
   (`Temucraft.Journal.ExportPath`).
2. Put `client/AddOns/TemucraftJournal` in the client's `Interface\AddOns` (or the client patch you ship) and the
   exported file in that folder, replacing the placeholder.
3. In game: `/journal`, `/dj` or the book on the minimap.

- Dungeons / Raids, then an instance, then a boss (or all bosses) and a difficulty.
- Opening it inside a dungeon or raid shows that instance at its difficulty.
- The boss model shows where the client can draw it.
- Hover an item for its tooltip, shift-click to link it, ctrl-click to try it on. Items the client hasn't seen are
  asked from the server and fill in a moment later.

The bosses come from DungeonEncounter.dbc and `instance_encounters` (bosses credited by a kill); loot from each
boss's `creature_loot_template` with references followed, per difficulty entry. Bosses whose loot is in a chest
(some raid encounters) or that are credited by a spell show without loot.

C++ (the export) and a plain Lua addon. No Eluna or AIO. Settings: `conf/mod-temucraft-journal.conf.dist`.

## Texts and translations

The 2 player-facing texts (chat messages, gossip options) are in the `module_string` table under the module name
`mod-temucraft-journal`, so they can be changed without rebuilding. Translations go in `module_string_locale` with the same
module and id plus the locale (`deDE`, `esES`, `frFR`, ...). If a row is missing the English text in the code is used.

Part of the Temucraft modules for AzerothCore 3.3.5a.
