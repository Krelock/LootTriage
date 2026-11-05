-- LootTriage's lines in item tooltips, added after Blizzard builds them:
-- starred items, items a quest needs, delete candidates with their number and
-- value, and in the loot window what to delete to make room.
local _, ns = ...

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local next = next

local KEEP_CLICKS, SHOW_OFF, loot, lootPairs = ns.KEEP_CLICKS, ns.SHOW_OFF, ns.loot, ns.lootPairs
local SlotKey, ValueText, NeededForQuest = ns.SlotKey, ns.ValueText, ns.NeededForQuest
local overlays, hookedBagButtons, rankBySlot, entryBySlot = ns.overlays, ns.hookedBagButtons, ns.rankBySlot, ns.entryBySlot
local OtherBagsInUse, PairValid, GOLD_R, GOLD_G, GOLD_B = ns.OtherBagsInUse, ns.PairValid, ns.GOLD_R, ns.GOLD_G, ns.GOLD_B
local LootSlotOf = ns.LootSlotOf

local function IsInside(frame, ancestor)
    while frame do
        if frame == ancestor then return true end
        frame = frame:GetParent()
    end
    return false
end

-- The click that stars a bag item ("Alt+Left-click"), for the tooltip in the bags.
local function KeepHint(inBags)
    local click = inBags and KEEP_CLICKS[ns.db.keepClick]
    return click and click.name
end

-- Bag addons whose buttons can't be drawn on still get the line: an item knows
-- the bag slot it's in.
local GetItemLocation = C_Item and C_Item.GetItemLocation

-- The number and candidate of the highlighted bag item with this GUID, if it's one.
local function HighlightFromGUID(guid)
    local loc = GetItemLocation and GetItemLocation(guid)
    if not loc or not loc.IsBagAndSlot or not loc:IsBagAndSlot() then return end
    local key = SlotKey(loc:GetBagAndSlot())
    local e = entryBySlot[key]
    if e then return rankBySlot[key], e end
end

local function AddTooltipLine(tooltip, data)
    if tooltip ~= GameTooltip or not ns.db then return end
    local owner = tooltip:GetOwner()
    local inBags = owner ~= nil and hookedBagButtons[owner] ~= nil

    local itemID = data and data.id
    if itemID and ns.db.keep[itemID] then
        local hint = KeepHint(inBags)
        tooltip:AddLine(hint and ("LootTriage: never suggested for deletion (%s to undo)"):format(hint)
            or "LootTriage: never suggested for deletion", 0.6, 0.8, 1)
        return
    end
    if itemID then
        -- Items bound as quest items say "Quest Item" already.
        local name, _, _, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(itemID)
        if name and bindType ~= 4 and NeededForQuest(itemID, name) then
            tooltip:AddLine("LootTriage: needed for a quest, never suggested for deletion", 0.6, 0.8, 1)
            -- The quests, each once (one in your log can be on the list too).
            local seen, lines, more = {}, 0, 0
            NeededForQuest(itemID, name, function(title, kind)
                if not title or seen[title] then return end
                seen[title] = true
                if lines == 5 then more = more + 1 return end
                lines = lines + 1
                tooltip:AddLine("  " .. title .. (kind == "log" and " (in your log)" or kind == "repeatable" and " (repeatable)" or ""),
                    0.6, 0.6, 0.6)
            end)
            if more > 0 then tooltip:AddLine(("  and %d more"):format(more), 0.6, 0.6, 0.6) end
        end
    end
    if not owner then return end

    local o = overlays[owner]
    if o and o.entry and o:IsShown() then
        tooltip:AddLine(("LootTriage: delete candidate #%d (%s)"):format(o.rank, ValueText(o.entry)),
            GOLD_R, GOLD_G, GOLD_B)
        local hint = KeepHint(inBags)
        if hint then
            tooltip:AddLine(hint .. " to never suggest this item for deletion", 0.6, 0.6, 0.6)
        end
        return
    end

    if data and data.guid and not inBags and next(entryBySlot) ~= nil and OtherBagsInUse() then
        local rank, e = HighlightFromGUID(data.guid)
        if rank then
            tooltip:AddLine(("LootTriage: delete candidate #%d (%s)"):format(rank, ValueText(e)),
                GOLD_R, GOLD_G, GOLD_B)
            return
        end
    end

    if not loot.session or next(lootPairs) == nil then return end
    if not (IsInside(owner, LootFrame) or IsInside(owner, PlumberLootWindow)) then return end
    local lootSlot = LootSlotOf(owner) or (owner:GetParent() and LootSlotOf(owner:GetParent()))
    local pair = lootSlot and lootPairs[lootSlot]
    if not pair or not pair.worth or not PairValid(pair) then return end
    local line = ns.db.highlightMode ~= SHOW_OFF
        and ("LootTriage: delete %s (#%d in your bags) to make room for this."):format(pair.link or "?", pair.rank)
        or ("LootTriage: delete %s to make room for this."):format(pair.link or "?")
    tooltip:AddLine(line, 0.2, 1, 0.2, true)
end

if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddTooltipLine)
end

ns.AddTooltipLine = AddTooltipLine
