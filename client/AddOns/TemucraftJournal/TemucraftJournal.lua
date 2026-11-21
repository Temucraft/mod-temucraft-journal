--[[
    TemucraftJournal: a dungeon journal for 3.3.5. Instances, their bosses and what each boss drops, per difficulty.
    The data (TemucraftJournal_Data.lua) is written by the server with .temucraft journal export, so custom bosses and loot
    are included. Open with /journal or /dj, or the book on the minimap.

    Hover an item for its tooltip, shift-click to link it in chat, ctrl-click to try it on.
--]]

local ROW_HEIGHT = 18
local INSTANCE_ROWS = 20
local BOSS_ROWS = 10
local LOOT_ROWS = 20

local DIFF_DUNGEON = { [0] = "Normal", [1] = "Heroic" }
local DIFF_RAID = { [0] = "10", [1] = "25", [2] = "10 Heroic", [3] = "25 Heroic" }
local EXPANSIONS = { [0] = "Classic", [1] = "TBC", [2] = "WotLK", [3] = "Cata", [4] = "MoP", [5] = "WoD",
                     [6] = "Legion", [7] = "BfA", [8] = "SL", [9] = "DF", [10] = "TWW" }

local state = { raid = false, instance = nil, boss = nil, diff = 0, instances = {}, loot = {} }
local pending = {}      -- items asked from the server, not in the cache yet

-------------------------------------------------------------------------------------------------------------------
-- Frame
-------------------------------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "TemucraftJournalFrame", UIParent)
frame:SetWidth(720)
frame:SetHeight(470)
frame:SetPoint("CENTER")
frame:SetFrameStrata("HIGH")
frame:SetToplevel(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:Hide()
tinsert(UISpecialFrames, "TemucraftJournalFrame")

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -18)
title:SetText("Dungeon Journal")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

local function Label(text, x, y)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Button(text, width, x, y, onClick)
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(20)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- A scrolling list of clickable rows
local function List(name, x, y, width, rows, update)
    local list = { rows = {}, count = rows }
    list.scroll = CreateFrame("ScrollFrame", "TemucraftJournal" .. name .. "Scroll", frame, "FauxScrollFrameTemplate")
    list.scroll:SetPoint("TOPLEFT", x, y)
    list.scroll:SetWidth(width)
    list.scroll:SetHeight(rows * ROW_HEIGHT)
    list.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, update)
    end)
    for i = 1, rows do
        local row = CreateFrame("Button", nil, frame)
        row:SetWidth(width)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", x, y - (i - 1) * ROW_HEIGHT)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(ROW_HEIGHT - 2)
        row.icon:SetHeight(ROW_HEIGHT - 2)
        row.icon:SetPoint("LEFT", 2, 0)
        row.icon:Hide()
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", -40, 0)
        row.text:SetJustifyH("LEFT")
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.right:SetPoint("RIGHT", -4, 0)
        row.selected = row:CreateTexture(nil, "BACKGROUND")
        row.selected:SetAllPoints()
        row.selected:SetTexture(1, 0.82, 0, 0.15)
        row.selected:Hide()
        list.rows[i] = row
    end
    return list
end

local function SetIcon(row, texture)
    if texture then
        row.icon:SetTexture(texture)
        row.icon:Show()
        row.text:SetPoint("LEFT", ROW_HEIGHT + 4, 0)
    else
        row.icon:Hide()
        row.text:SetPoint("LEFT", 4, 0)
    end
end

-------------------------------------------------------------------------------------------------------------------
-- Data helpers
-------------------------------------------------------------------------------------------------------------------

local query = CreateFrame("GameTooltip", "TemucraftJournalQueryTooltip", nil, "GameTooltipTemplate")
query:SetOwner(UIParent, "ANCHOR_NONE")

-- Name, link, colour and icon of an item; asks the server for it the first time it isn't cached
local function ItemData(id)
    local name, link, quality, _, _, _, _, _, _, texture = GetItemInfo(id)
    if name then
        pending[id] = nil
        local r, g, b = GetItemQualityColor(quality or 1)
        return name, link, r, g, b, texture
    end
    if pending[id] == nil then
        pending[id] = true
        query:SetHyperlink("item:" .. id)
    end
    return "Item " .. id .. " (loading)", nil, 0.6, 0.6, 0.6, GetItemIcon and GetItemIcon(id) or nil
end

local function BuildInstanceList()
    wipe(state.instances)
    for _, inst in ipairs(TemucraftJournalData or {}) do
        if inst.raid == state.raid and #inst.bosses > 0 then
            tinsert(state.instances, inst)
        end
    end
    table.sort(state.instances, function(a, b)
        if a.exp ~= b.exp then return a.exp < b.exp end
        return a.name < b.name
    end)
end

local function DifficultyName(inst, d)
    return (inst.raid and DIFF_RAID[d] or DIFF_DUNGEON[d]) or ("Difficulty " .. (d + 1))
end

local function BuildLoot()
    wipe(state.loot)
    local inst = state.instance
    if not inst then return end
    local seen = {}
    local bosses = state.boss and { state.boss } or inst.bosses
    for _, boss in ipairs(bosses) do
        for _, item in ipairs(boss.loot[state.diff] or {}) do
            if not seen[item] then
                seen[item] = true
                tinsert(state.loot, item)
            end
        end
    end
end

-------------------------------------------------------------------------------------------------------------------
-- Lists
-------------------------------------------------------------------------------------------------------------------

local instanceList, bossList, lootList
local diffButtons = {}
local model, bossTitle, lootTitle, emptyText

local function UpdateInstances()
    local offset = FauxScrollFrame_GetOffset(instanceList.scroll)
    FauxScrollFrame_Update(instanceList.scroll, #state.instances, INSTANCE_ROWS, ROW_HEIGHT)
    for i, row in ipairs(instanceList.rows) do
        local inst = state.instances[i + offset]
        if inst then
            row.text:SetText(inst.name)
            row.right:SetText(EXPANSIONS[inst.exp] or ("Exp " .. inst.exp))
            if inst == state.instance then row.selected:Show() else row.selected:Hide() end
            row.data = inst
            row:Show()
        else
            row:Hide()
        end
    end
end

local function UpdateBosses()
    local inst = state.instance
    local bosses = inst and inst.bosses or {}
    local total = #bosses + (inst and 1 or 0)        -- first row: all bosses
    local offset = FauxScrollFrame_GetOffset(bossList.scroll)
    FauxScrollFrame_Update(bossList.scroll, total, BOSS_ROWS, ROW_HEIGHT)
    for i, row in ipairs(bossList.rows) do
        local index = i + offset
        if inst and index == 1 then
            row.text:SetText("|cffffd100All bosses|r")
            row.right:SetText("")
            if state.boss == nil then row.selected:Show() else row.selected:Hide() end
            row.data = false
            row:Show()
        elseif inst and bosses[index - 1] then
            local boss = bosses[index - 1]
            row.text:SetText(boss.name)
            row.right:SetText("")
            if boss == state.boss then row.selected:Show() else row.selected:Hide() end
            row.data = boss
            row:Show()
        else
            row:Hide()
        end
    end
end

local function UpdateModel()
    local boss = state.boss
    if boss and boss.npc and boss.npc > 0 and model.SetCreature then
        model:ClearModel()
        if pcall(model.SetCreature, model, boss.npc) then
            model:Show()
            return
        end
    end
    model:Hide()
end

local function UpdateLoot()
    local offset = FauxScrollFrame_GetOffset(lootList.scroll)
    FauxScrollFrame_Update(lootList.scroll, #state.loot, LOOT_ROWS, ROW_HEIGHT)
    for i, row in ipairs(lootList.rows) do
        local id = state.loot[i + offset]
        if id then
            local name, link, r, g, b, texture = ItemData(id)
            SetIcon(row, texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.text:SetText(name)
            row.text:SetTextColor(r, g, b)
            row.right:SetText("")
            row.data = id
            row:Show()
        else
            row:Hide()
        end
    end
    local inst = state.instance
    if inst then
        lootTitle:SetText((state.boss and state.boss.name or "All bosses") .. " - " .. DifficultyName(inst, state.diff)
            .. " (" .. #state.loot .. " items)")
    else
        lootTitle:SetText("Loot")
    end
end

local function UpdateDifficulties()
    local inst = state.instance
    local x = 0
    for d = 0, 3 do
        local b = diffButtons[d]
        if inst and bit.band(inst.diff or 1, bit.lshift(1, d)) ~= 0 then
            b:SetText(DifficultyName(inst, d))
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", 440 + x, -50)
            x = x + 68
            if d == state.diff then b:LockHighlight() else b:UnlockHighlight() end
            b:Show()
        else
            b:Hide()
        end
    end
end

local function Refresh()
    if not TemucraftJournalData or #TemucraftJournalData == 0 then
        emptyText:Show()
    else
        emptyText:Hide()
    end
    BuildLoot()
    UpdateInstances()
    UpdateBosses()
    UpdateDifficulties()
    UpdateLoot()
    UpdateModel()
    bossTitle:SetText(state.instance and state.instance.name or "Bosses")
end

local function SelectInstance(inst)
    state.instance = inst
    state.boss = nil
    if inst and bit.band(inst.diff or 1, bit.lshift(1, state.diff)) == 0 then
        state.diff = 0
    end
    FauxScrollFrame_SetOffset(bossList.scroll, 0)
    bossList.scroll:SetVerticalScroll(0)
    FauxScrollFrame_SetOffset(lootList.scroll, 0)
    lootList.scroll:SetVerticalScroll(0)
    Refresh()
end

local function ShowKind(raid)
    state.raid = raid
    BuildInstanceList()
    FauxScrollFrame_SetOffset(instanceList.scroll, 0)
    instanceList.scroll:SetVerticalScroll(0)
    SelectInstance(nil)
end

-------------------------------------------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------------------------------------------

Button("Dungeons", 90, 24, -50, function() ShowKind(false) end)
Button("Raids", 90, 118, -50, function() ShowKind(true) end)

Label("Instances", 26, -78)
instanceList = List("Instances", 22, -92, 200, INSTANCE_ROWS, UpdateInstances)
for _, row in ipairs(instanceList.rows) do
    row:SetScript("OnClick", function(self) if self.data then SelectInstance(self.data) end end)
end

bossTitle = Label("Bosses", 250, -78)
bossList = List("Bosses", 246, -92, 170, BOSS_ROWS, UpdateBosses)
for _, row in ipairs(bossList.rows) do
    row:SetScript("OnClick", function(self)
        state.boss = self.data or nil
        FauxScrollFrame_SetOffset(lootList.scroll, 0)
        lootList.scroll:SetVerticalScroll(0)
        Refresh()
    end)
end

model = CreateFrame("PlayerModel", nil, frame)
model:SetWidth(170)
model:SetHeight(170)
model:SetPoint("TOPLEFT", 246, -92 - BOSS_ROWS * ROW_HEIGHT - 10)
model:Hide()

for d = 0, 3 do
    diffButtons[d] = Button("", 66, 440, -50, function()
        state.diff = d
        FauxScrollFrame_SetOffset(lootList.scroll, 0)
        lootList.scroll:SetVerticalScroll(0)
        Refresh()
    end)
    diffButtons[d]:Hide()
end

lootTitle = Label("Loot", 444, -78)
lootList = List("Loot", 440, -92, 250, LOOT_ROWS, UpdateLoot)
for _, row in ipairs(lootList.rows) do
    row:SetScript("OnEnter", function(self)
        if not self.data then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. self.data)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if not self.data then return end
        local _, link = GetItemInfo(self.data)
        if not link then return end
        if IsModifiedClick("CHATLINK") then
            ChatEdit_InsertLink(link)
        elseif IsModifiedClick("DRESSUP") then
            DressUpItemLink(link)
        end
    end)
end

emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
emptyText:SetPoint("CENTER")
emptyText:SetText("No journal data. On the server: .temucraft journal export, then copy\nTemucraftJournal_Data.lua into this addon's folder.")
emptyText:Hide()

-- Items arrive from the server a moment after they're asked for: redraw while some are still loading
local elapsedSince = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < 0.5 then return end
    elapsedSince = 0
    if next(pending) then UpdateLoot() end
end)

-- Opening inside a dungeon or raid shows that instance at its difficulty
frame:SetScript("OnShow", function()
    local name, kind = GetInstanceInfo()
    if kind == "party" or kind == "raid" then
        state.raid = (kind == "raid")
        BuildInstanceList()
        for _, inst in ipairs(state.instances) do
            if inst.name == name then
                local difficulty = GetInstanceDifficulty and GetInstanceDifficulty() or 1
                state.diff = math.max(0, (difficulty or 1) - 1)
                SelectInstance(inst)
                return
            end
        end
    end
    BuildInstanceList()
    Refresh()
end)

-------------------------------------------------------------------------------------------------------------------
-- Opening it: slash commands and a minimap button
-------------------------------------------------------------------------------------------------------------------

local function Toggle()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

SLASH_TEMUCRAFTJOURNAL1 = "/journal"
SLASH_TEMUCRAFTJOURNAL2 = "/dj"
SlashCmdList["TEMUCRAFTJOURNAL"] = Toggle

local minimapButton = CreateFrame("Button", "TemucraftJournalMinimapButton", Minimap)
minimapButton:SetWidth(31)
minimapButton:SetHeight(31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
icon:SetWidth(20)
icon:SetHeight(20)
icon:SetPoint("TOPLEFT", 7, -5)
local border = minimapButton:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetWidth(53)
border:SetHeight(53)
border:SetPoint("TOPLEFT")
local angle = math.rad(200)
minimapButton:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
minimapButton:SetScript("OnClick", Toggle)
minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Dungeon Journal")
    GameTooltip:AddLine("Bosses and their loot. /journal", 1, 1, 1)
    GameTooltip:Show()
end)
minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
