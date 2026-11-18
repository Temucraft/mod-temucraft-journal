/*
 * mod-temucraft-journal: writes the data of the TemucraftJournal client addon (a dungeon journal for 3.3.5) from
 * the server's own data, so custom bosses and loot show up too.
 *
 *   .journal export    writes Temucraft.Journal.ExportPath (TemucraftJournal_Data.lua next to worldserver by
 *                      default). Copy it into Interface\AddOns\TemucraftJournal\ of the client (or the client
 *                      patch you ship) and /reload.
 *
 * Instances and bosses come from DungeonEncounter.dbc and instance_encounters (bosses credited by a kill), the loot
 * from each boss's creature_loot_template, with references followed, per difficulty (the boss's difficulty
 * entries). Items below Temucraft.Journal.MinQuality are left out.
 */

#include "Chat.h"
#include "TemucraftModuleText.h"
#include "ChatCommand.h"
#include "Config.h"
#include "DBCStores.h"
#include "DatabaseEnv.h"
#include "ObjectMgr.h"
#include "ScriptMgr.h"

#include <algorithm>
#include <fstream>
#include <map>
#include <set>
#include <unordered_map>
#include <vector>

using namespace Acore::ChatCommands;

namespace
{
    struct Boss
    {
        std::string name;
        uint32 order = 0;
        uint32 npc = 0;
        std::map<uint8, std::set<uint32>> loot;   // difficulty -> items
    };

    struct Instance
    {
        uint32 map = 0;
        std::string name;
        bool raid = false;
        uint32 expansion = 0;
        uint8 difficulties = 0;                    // bit mask
        std::vector<Boss> bosses;
    };

    std::string Lua(std::string const& text)
    {
        std::string out = "\"";
        for (char ch : text)
        {
            if (ch == '"' || ch == '\\')
                out += '\\';
            if (ch == '\n')
            {
                out += "\\n";
                continue;
            }
            out += ch;
        }
        return out + "\"";
    }

    using LootRows = std::unordered_map<uint32, std::vector<std::pair<uint32, uint32>>>;   // entry -> (item, reference)

    void QueryLoot(char const* table, std::set<uint32> const& entries, LootRows& rows)
    {
        std::vector<uint32> list(entries.begin(), entries.end());
        for (size_t start = 0; start < list.size(); start += 500)
        {
            std::string in;
            for (size_t i = start; i < std::min(list.size(), start + 500); ++i)
                in += (in.empty() ? "" : ",") + std::to_string(list[i]);
            if (QueryResult result = WorldDatabase.Query("SELECT `Entry`, `Item`, `Reference` FROM `{}` WHERE `Entry` IN ({})", table, in))
            {
                do
                {
                    Field* f = result->Fetch();
                    rows[f[0].Get<uint32>()].emplace_back(f[1].Get<uint32>(), f[2].Get<uint32>());
                } while (result->NextRow());
            }
        }
    }

    // Every reference reachable from the given loot, loaded in rounds
    void LoadReferences(LootRows const& base, LootRows& refs)
    {
        std::set<uint32> wanted;
        auto collect = [&](LootRows const& rows)
        {
            for (auto const& [entry, list] : rows)
                for (auto const& [item, ref] : list)
                    if (ref && !refs.count(ref))
                        wanted.insert(ref);
        };
        collect(base);
        for (int round = 0; round < 6 && !wanted.empty(); ++round)
        {
            std::set<uint32> now;
            now.swap(wanted);
            LootRows fresh;
            QueryLoot("reference_loot_template", now, fresh);
            for (uint32 id : now)
                refs[id] = fresh.count(id) ? fresh[id] : std::vector<std::pair<uint32, uint32>>();
            collect(fresh);
        }
    }

    void Expand(uint32 entry, LootRows const& rows, LootRows const& refs, std::set<uint32>& out, uint32 minQuality, int depth = 0)
    {
        auto itr = rows.find(entry);
        if (itr == rows.end() || depth > 6)
            return;
        for (auto const& [item, ref] : itr->second)
        {
            if (ref)
            {
                Expand(ref, refs, refs, out, minQuality, depth + 1);
                continue;
            }
            ItemTemplate const* proto = sObjectMgr->GetItemTemplate(item);
            if (proto && proto->Quality >= minQuality && proto->Class != ITEM_CLASS_QUEST)
                out.insert(item);
        }
    }
}

class TemucraftJournal_Commands : public CommandScript
{
public:
    TemucraftJournal_Commands() : CommandScript("TemucraftJournal_Commands") { }

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable journalTable =
        {
            { "export", HandleExport, 100901 /* SEC_ADMINISTRATOR -> RBAC */, Console::Yes },
        };
        static ChatCommandTable commandTable =
        {
            { "journal", journalTable },
        };
        return commandTable;
    }

    static bool HandleExport(ChatHandler* handler)
    {
        uint32 minQuality = sConfigMgr->GetOption<uint32>("Temucraft.Journal.MinQuality", 2);
        std::string path = sConfigMgr->GetOption<std::string>("Temucraft.Journal.ExportPath", "TemucraftJournal_Data.lua");

        // Which creature gives credit for each encounter
        std::unordered_map<uint32, uint32> creditNpc;
        if (QueryResult result = WorldDatabase.Query("SELECT `entry`, `creditEntry` FROM `instance_encounters` WHERE `creditType` = 0"))
        {
            do
            {
                Field* f = result->Fetch();
                creditNpc[f[0].Get<uint32>()] = f[1].Get<uint32>();
            } while (result->NextRow());
        }

        // Instances and bosses (one boss per map and encounter index, over all difficulties)
        std::map<uint32, Instance> instances;
        std::map<std::pair<uint32, uint32>, size_t> bossIndex;
        for (uint32 i = 0; i < sDungeonEncounterStore.GetNumRows(); ++i)
        {
            DungeonEncounterEntry const* enc = sDungeonEncounterStore.LookupEntry(i);
            if (!enc)
                continue;
            MapEntry const* map = sMapStore.LookupEntry(enc->mapId);
            if (!map || !map->IsDungeon())
                continue;
            Instance& inst = instances[enc->mapId];
            if (!inst.map)
            {
                inst.map = enc->mapId;
                inst.name = map->name[LOCALE_enUS];
                inst.raid = map->IsRaid();
                inst.expansion = map->Expansion();
            }
            inst.difficulties |= 1 << enc->difficulty;
            auto key = std::make_pair(enc->mapId, enc->encounterIndex);
            if (!bossIndex.count(key))
            {
                bossIndex[key] = inst.bosses.size();
                Boss boss;
                boss.name = enc->encounterName[LOCALE_enUS] ? enc->encounterName[LOCALE_enUS] : "?";
                boss.order = enc->encounterIndex;
                inst.bosses.push_back(boss);
            }
            Boss& boss = inst.bosses[bossIndex[key]];
            if (!boss.npc && creditNpc.count(enc->id))
                boss.npc = creditNpc[enc->id];
        }

        // Loot ids per boss and difficulty: the boss, then its difficulty entries
        std::set<uint32> lootIds;
        auto lootOf = [](uint32 npc, uint8 diff) -> uint32
        {
            CreatureTemplate const* t = sObjectMgr->GetCreatureTemplate(npc);
            if (!t)
                return 0;
            if (diff > 0)
            {
                uint32 diffNpc = t->DifficultyEntry[diff - 1];
                CreatureTemplate const* d = diffNpc ? sObjectMgr->GetCreatureTemplate(diffNpc) : nullptr;
                return d ? d->lootid : 0;
            }
            return t->lootid;
        };
        for (auto& [mapId, inst] : instances)
            for (Boss& boss : inst.bosses)
                for (uint8 d = 0; d < MAX_DIFFICULTY; ++d)
                    if ((inst.difficulties & (1 << d)) && boss.npc)
                        if (uint32 id = lootOf(boss.npc, d))
                            lootIds.insert(id);

        LootRows base, refs;
        QueryLoot("creature_loot_template", lootIds, base);
        LoadReferences(base, refs);

        uint32 bosses = 0, items = 0;
        for (auto& [mapId, inst] : instances)
            for (Boss& boss : inst.bosses)
            {
                ++bosses;
                for (uint8 d = 0; d < MAX_DIFFICULTY; ++d)
                    if ((inst.difficulties & (1 << d)) && boss.npc)
                        if (uint32 id = lootOf(boss.npc, d))
                        {
                            Expand(id, base, refs, boss.loot[d], minQuality);
                            items += boss.loot[d].size();
                        }
            }

        std::ofstream file(path, std::ios::trunc);
        if (!file)
        {
            handler->PSendSysMessage(TemucraftModuleText("mod-temucraft-journal", handler, 1, "Could not write {}."), path);
            return false;
        }
        file << "-- TemucraftJournal data, written by the server (.journal export). Do not edit: export again.\n";
        file << "TemucraftJournalData = {\n";
        for (auto& [mapId, inst] : instances)
        {
            std::sort(inst.bosses.begin(), inst.bosses.end(), [](Boss const& a, Boss const& b) { return a.order < b.order; });
            file << "  {map=" << inst.map << ", name=" << Lua(inst.name) << ", raid=" << (inst.raid ? "true" : "false")
                 << ", exp=" << inst.expansion << ", diff=" << uint32(inst.difficulties) << ", bosses={\n";
            for (Boss const& boss : inst.bosses)
            {
                file << "    {name=" << Lua(boss.name) << ", npc=" << boss.npc << ", loot={";
                for (auto const& [d, list] : boss.loot)
                {
                    file << "[" << uint32(d) << "]={";
                    bool first = true;
                    for (uint32 item : list)
                    {
                        file << (first ? "" : ",") << item;
                        first = false;
                    }
                    file << "},";
                }
                file << "}},\n";
            }
            file << "  }},\n";
        }
        file << "}\n";
        file.close();

        handler->PSendSysMessage(TemucraftModuleText("mod-temucraft-journal", handler, 2, "Journal: {} instances, {} bosses, {} loot entries written to {}. Copy it into "
                                 "Interface\\AddOns\\TemucraftJournal\\ and /reload."), instances.size(), bosses, items, path);
        return true;
    }
};

void AddTemucraftJournalScripts()
{
    new TemucraftJournal_Commands();
}
