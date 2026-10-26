-- LootTriage's quest items: bag items a quest asks for are never suggested for
-- deletion. They come from your quest log's objectives and, on WoW Forever,
-- from QuestItems.lua's list of what the original game's quests ask for.
--
-- Sections: Quest log, Quest list, Events.
local _, ns = ...

local ipairs, pairs, wipe = ipairs, pairs, wipe
local After = C_Timer.After
local band = bit and bit.band

local IS_RETAIL, events, loot = ns.IS_RETAIL, ns.events, ns.loot

---------------------------------------------------------------------------
-- Quest log
---------------------------------------------------------------------------
-- An objective names its item but gives no item ID, so items match by name.

-- The list is the original game's quests. Retail replaced them, so there it's
-- the quest log only.
local questItems = not IS_RETAIL and ns.questItems or {}
local questRaces = ns.questRaces or {}
local questClasses = ns.questClasses or {}
local repeatableQuests = ns.repeatableQuests or {}
local QuestLog = C_QuestLog
local IsQuestDone = QuestLog and QuestLog.IsQuestFlaggedCompleted
local logNames, freshNames = {}, {} -- [item name] = quest title, or true
local logRead, checkQueued = false, false
local playerLevel -- from PLAYER_LEVEL_UP, when UnitLevel can still say the old level

-- "Murloc Eye: 2/3" or "2/3 Murloc Eye" -> "Murloc Eye"
local function ObjectiveItem(text)
    return text:match("^(.-):%s*%d+%s*/%s*%d+%s*$") or text:match("^%s*%d+%s*/%s*%d+%s+(.-)%s*$") or text
end

-- Reads the log's item objectives; true if they changed.
local function ReadQuestLog()
    logRead = true
    wipe(freshNames)
    if QuestLog and QuestLog.GetNumQuestLogEntries then
        for i = 1, QuestLog.GetNumQuestLogEntries() do
            local info = QuestLog.GetInfo(i)
            local objectives = info and not info.isHeader and info.questID
                and QuestLog.GetQuestObjectives(info.questID)
            if objectives then
                for _, o in ipairs(objectives) do
                    if o.type == "item" and o.text then freshNames[ObjectiveItem(o.text)] = info.title or true end
                end
            end
        end
    end
    local changed = false
    for name in pairs(freshNames) do
        if not logNames[name] then changed = true break end
    end
    for name in pairs(logNames) do
        if not freshNames[name] then changed = true break end
    end
    logNames, freshNames = freshNames, logNames
    return changed
end

---------------------------------------------------------------------------
-- Quest list
---------------------------------------------------------------------------
-- A quest not picked up yet keeps its items until it's done (a repeatable one
-- always, with its own setting), if your race, class and level fit.

-- Race and class masks: bit n-1 is ID n.
local function Bit(id) return id and id > 0 and 2 ^ (id - 1) or 0 end

local function CanDo(questID)
    local races, classes = questRaces[questID], questClasses[questID]
    if not band or not (races or classes) then return true end
    return (not races or band(races, Bit(select(3, UnitRace("player")))) ~= 0)
        and (not classes or band(classes, Bit(select(3, UnitClass("player")))) ~= 0)
end

-- Within Quest levels above yours, and not gray (Blizzard's quest colors) with
-- Skip low-level quests on.
local questMinLevels = ns.questMinLevels or {}
local questLevels = ns.questLevels or {}
local TrivialRange = UnitQuestTrivialLevelRange
local function LevelFits(questID, level)
    local minLevel, questLevel = questMinLevels[questID], questLevels[questID]
    if minLevel and minLevel > level + ns.db.questLevelsAbove then return false end
    if ns.db.skipGrayQuests and questLevel and TrivialRange
            and level - questLevel > TrivialRange("player") then
        return false
    end
    return true
end

-- A quest's name in the game's language. Until the game has loaded the quest,
-- its ID, and the game is asked for it.
local function QuestTitle(questID)
    local title = QuestLog and QuestLog.GetTitleForQuestID and QuestLog.GetTitleForQuestID(questID)
    if title then return title end
    if QuestLog and QuestLog.RequestLoadQuestByID then
        QuestLog.RequestLoadQuestByID(questID)
        events:RegisterEvent("QUEST_DATA_LOAD_RESULT")
    end
    return ("Quest %d"):format(questID)
end

-- Whether a quest keeps the item. With `found`, calls found(quest name or nil,
-- "log", "repeatable" or nil) for each quest that does.
local function NeededForQuest(itemID, name, found)
    if ns.db.keepQuestItems and name then
        if not logRead then ReadQuestLog() end
        local title = logNames[name]
        if title then
            if not found then return true end
            found(type(title) == "string" and title or nil, "log")
        end
    end
    local quests = questItems[itemID]
    if not quests then return false end
    local level = playerLevel or UnitLevel("player")
    for _, questID in ipairs(quests) do
        if CanDo(questID) then
            local repeatable = repeatableQuests[questID]
            local keep
            if repeatable then
                keep = ns.db.keepRepeatableQuestItems
            else
                keep = ns.db.keepUnstartedQuestItems and not (IsQuestDone and IsQuestDone(questID))
                    and LevelFits(questID, level)
            end
            if keep then
                if not found then return true end
                found(QuestTitle(questID), repeatable and "repeatable" or nil)
            end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function CheckQuestLog()
    checkQueued = false
    if ReadQuestLog() then ns.OnOptionsChanged() end
end

-- QUEST_LOG_UPDATE comes often: the log is read once a frame while the bags or
-- the loot window are open, and otherwise by the next scan.
local function OnQuestLogUpdate(event)
    -- A quest's name came: draw the tooltip that asked for it again.
    if event == "QUEST_DATA_LOAD_RESULT" then
        events:UnregisterEvent("QUEST_DATA_LOAD_RESULT")
        if GameTooltip:IsShown() and GameTooltip.RefreshData then GameTooltip:RefreshData() end
        return
    end
    if loot.open or ns.BagsOpen() then
        if not checkQueued then
            checkQueued = true
            After(0, CheckQuestLog)
        end
    else
        logRead = false
    end
end

local function OnLevelUp(level)
    playerLevel = level
    if ns.db.keepUnstartedQuestItems then ns.OnOptionsChanged() end
end

ns.NeededForQuest, ns.OnQuestLogUpdate, ns.OnLevelUp = NeededForQuest, OnQuestLogUpdate, OnLevelUp
