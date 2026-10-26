-- LootTriage's sorting: after Blizzard's bag sort, the junk goes to the bottom
-- right corner, the cheapest in the very last slot (or with Top left, the top
-- left corner and the very first slot). With Close gaps after sorting, the other
-- items close up in Blizzard's order and the free slots end up together.
--
-- Sections: Slots, Junk to a corner, Close gaps, Running the sort.
local _, ns = ...

local C_Container = C_Container
local GetContainerItemInfo = C_Container.GetContainerItemInfo
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetTime = GetTime
local ipairs, pairs, wipe = ipairs, pairs, wipe
local sort, min, floor = table.sort, math.min, math.floor

local IS_RETAIL, LAST_BAG, SORT_OFF, SORT_TOP_LEFT = ns.IS_RETAIL, ns.LAST_BAG, ns.SORT_OFF, ns.SORT_TOP_LEFT
local events, candidates, visualIndex = ns.events, ns.candidates, ns.visualIndex
local SlotKey, NormalBags, ScanBags = ns.SlotKey, ns.NormalBags, ns.ScanBags
local ForEachBagButton, Rebuild = ns.ForEachBagButton, ns.Rebuild

-- Each move that shares no slot with another is made at once, and the next
-- round only waits until the server has confirmed them (the items unlock).
-- Most sorts take 1-3 rounds, 3-6 with Close gaps.
local lastBagChange = 0
local sortSawChange = false  -- Blizzard's sort has started moving items
local sortTicker, sortStart, sortRounds

local SORT_TICK = 0.05        -- seconds between looks at the bags
local SORT_QUIET_TIME = 0.1   -- how long the bags must be still before a round
local SORT_NO_CHANGE_WAIT = 0.6 -- when Blizzard's sort moves nothing, start after this
local SORT_TIMEOUT = 15
local SORT_MAX_ROUNDS = 30

local sortableBags, sortSlots, slotPool, seenSlots, sortItems, touchedSlots = {}, {}, {}, {}, {}, {}

-- Close gaps: the layout to sort into, worked out once from Blizzard's result
-- and kept for the whole sort. plan.id/count/link[slotKey] is the item that
-- goes there (none: a free slot). The junk goes to the corner and every other
-- item keeps Blizzard's order from the other corner, so the free slots end up
-- together instead of where the junk was.
local plan = { made = false, id = {}, count = {}, link = {}, junk = {} }
-- What each slot of the sortable bags holds this round.
local held = { keys = {}, id = {}, count = {}, link = {}, locked = {} }

local function WipeLists(t)
    for _, list in pairs(t) do
        if type(list) == "table" then wipe(list) end
    end
end

local function NoteBagChange()
    lastBagChange = GetTime()
    sortSawChange = true
end

local function AnyItemLocked()
    for _, bag in ipairs(NormalBags()) do
        for slot = 1, GetContainerNumSlots(bag) do
            local info = GetContainerItemInfo(bag, slot)
            if info and info.isLocked then return true end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------

-- A bag set to Ignore this bag > Cleanup in its menu.
local function SortDisabled(bag)
    if bag == 0 then
        return C_Container.GetBackpackAutosortDisabled and C_Container.GetBackpackAutosortDisabled() or false
    end
    if C_Container.GetBagSlotFlag and Enum.BagSlotFlags and Enum.BagSlotFlags.DisableAutoSort then
        return C_Container.GetBagSlotFlag(bag, Enum.BagSlotFlags.DisableAutoSort) or false
    end
    return false
end

local function SortableBags()
    wipe(sortableBags)
    for _, bag in ipairs(NormalBags()) do
        if not SortDisabled(bag) then sortableBags[bag] = true end
    end
    return sortableBags
end

local function CollectSlot(button, bag, slot)
    if not bag or not slot or not sortableBags[bag] then return end
    local key = SlotKey(bag, slot)
    if seenSlots[key] or not button:IsVisible() then return end
    local x, y = button:GetCenter()
    if not x then return end
    seenSlots[key] = true

    local scale = button:GetEffectiveScale()
    local n = #slotPool
    local s = slotPool[n]
    if s then slotPool[n] = nil else s = {} end
    -- Rounded, so buttons in one row are level (and the sort's order stays valid).
    s.bag, s.slot, s.x, s.y = bag, slot, floor(x * scale + 0.5), floor(y * scale + 0.5)
    sortSlots[#sortSlots + 1] = s
end

local function BottomRightFirst(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x > b.x
end

local function TopLeftFirst(a, b)
    return BottomRightFirst(b, a)
end

-- The sortable bags' slots on screen, from the corner: from the bottom right,
-- the bottom row right to left, then the row above (from the top left, the
-- other way round). By the buttons' places, so bags combined or not both work.
local function CornerSlots()
    for i = #sortSlots, 1, -1 do
        slotPool[#slotPool + 1] = sortSlots[i]
        sortSlots[i] = nil
    end
    wipe(seenSlots)
    ForEachBagButton(CollectSlot)
    sort(sortSlots, ns.db.sortCorner == SORT_TOP_LEFT and TopLeftFirst or BottomRightFirst)
    return sortSlots
end

-- Each slot's place from the corner, to number identical stacks by. None with
-- the bags closed: they go by bag and slot then.
local function UpdateVisualIndex()
    wipe(visualIndex)
    wipe(sortableBags)
    for _, bag in ipairs(NormalBags()) do sortableBags[bag] = true end
    for i, s in ipairs(CornerSlots()) do
        visualIndex[SlotKey(s.bag, s.slot)] = i
    end
end

local function IsLocked(bag, slot)
    local info = GetContainerItemInfo(bag, slot)
    return info ~= nil and info.isLocked
end

---------------------------------------------------------------------------
-- Junk to a corner
---------------------------------------------------------------------------

-- One round: each item not in its slot yet is swapped there at once, but for
-- moves sharing a slot with another (the next round). True while any is out of place.
local function SortRound()
    ScanBags()
    local bags = SortableBags()
    local targets = CornerSlots()
    wipe(sortItems)
    for _, e in ipairs(candidates) do
        if bags[e.bag] then sortItems[#sortItems + 1] = e end
    end

    wipe(touchedSlots)
    local pending = false
    for i = 1, min(#sortItems, #targets) do
        local item, target = sortItems[i], targets[i]
        if item.bag ~= target.bag or item.slot ~= target.slot then
            local there = GetContainerItemInfo(target.bag, target.slot)
            local identical = there and there.itemID == item.itemID and there.stackCount == item.count
                and (not IS_RETAIL or there.hyperlink == item.link) -- Retail: the item level too
            if not identical then
                pending = true
                local from, to = SlotKey(item.bag, item.slot), SlotKey(target.bag, target.slot)
                if not touchedSlots[from] and not touchedSlots[to]
                        and not IsLocked(item.bag, item.slot) and not IsLocked(target.bag, target.slot) then
                    C_Container.PickupContainerItem(item.bag, item.slot)
                    C_Container.PickupContainerItem(target.bag, target.slot)
                    if CursorHasItem() then ClearCursor() end
                    touchedSlots[from], touchedSlots[to] = true, true
                end
            end
        end
    end
    return pending
end

---------------------------------------------------------------------------
-- Close gaps
---------------------------------------------------------------------------

local function ReadSlots(bags)
    WipeLists(held)
    for bag = 0, LAST_BAG do
        if bags[bag] then
            for slot = 1, GetContainerNumSlots(bag) do
                local key = SlotKey(bag, slot)
                held.keys[#held.keys + 1] = key
                local info = GetContainerItemInfo(bag, slot)
                if info then
                    held.id[key], held.count[key], held.link[key], held.locked[key] =
                        info.itemID, info.stackCount or 1, info.hyperlink, info.isLocked
                end
            end
        end
    end
end

-- Whether slot `key` holds the item planned for slot `target`: the same item
-- and stack size (Retail: the item level too).
local function Holds(key, target)
    return held.id[key] == plan.id[target] and held.count[key] == plan.count[target]
        and (not IS_RETAIL or held.link[key] == plan.link[target])
end

local function PlanSlot(target, id, count, link)
    local key = SlotKey(target.bag, target.slot)
    plan.id[key], plan.count[key], plan.link[key] = id, count, link
end

-- targets: the slots from the corner; junk: deletable items, cheapest first.
local function MakePlan(targets, junk)
    local n, nJunk = #targets, min(#junk, #targets)
    for i = 1, nJunk do
        local e = junk[i]
        PlanSlot(targets[i], e.itemID, e.count, e.link)
        plan.junk[SlotKey(e.bag, e.slot)] = true
    end
    -- The other items, in screen order, fill the rest in screen order: from
    -- the top left (Bottom right), or after the junk (Top left).
    local topLeft = ns.db.sortCorner == SORT_TOP_LEFT
    local first, last, step = n, 1, -1
    if topLeft then first, last, step = 1, n, 1 end
    local to = topLeft and nJunk + 1 or n
    for i = first, last, step do
        local key = SlotKey(targets[i].bag, targets[i].slot)
        if held.id[key] and not plan.junk[key] then
            -- No room left: some junk came from a bag that isn't open.
            if to <= nJunk or to > n then break end
            PlanSlot(targets[to], held.id[key], held.count[key], held.link[key])
            to = to + step
        end
    end
    plan.made = true
end

-- One round: each planned slot without its item gets it, at once, from a slot
-- where it doesn't belong (as SortRound). True while any is out of place.
local function CloseGapsRound()
    -- Scan first: a tie makes the scan work out screen order in these same
    -- tables (UpdateVisualIndex), which would put every bag in them.
    if not plan.made then ScanBags() end
    local bags = SortableBags()
    local targets = CornerSlots()
    ReadSlots(bags)
    if not plan.made then
        wipe(sortItems)
        for _, e in ipairs(candidates) do
            if bags[e.bag] then sortItems[#sortItems + 1] = e end
        end
        MakePlan(targets, sortItems)
    end

    wipe(touchedSlots)
    local pending = false
    for _, target in ipairs(targets) do
        local to = SlotKey(target.bag, target.slot)
        if plan.id[to] and not Holds(to, to) then
            -- From a slot where it doesn't belong. With none (it was used,
            -- deleted or merged into another stack), it's skipped.
            for _, from in ipairs(held.keys) do
                if Holds(from, to) and not (plan.id[from] and Holds(from, from)) then
                    pending = true
                    if not touchedSlots[from] and not touchedSlots[to]
                            and not held.locked[from] and not held.locked[to] then
                        C_Container.PickupContainerItem(floor(from / 1000), from % 1000) -- SlotKey's bag, slot
                        C_Container.PickupContainerItem(target.bag, target.slot)
                        if CursorHasItem() then ClearCursor() end
                        touchedSlots[from], touchedSlots[to] = true, true
                    end
                    break
                end
            end
        end
    end
    return pending
end

---------------------------------------------------------------------------
-- Running the sort
---------------------------------------------------------------------------

local function StopSort()
    if sortTicker then
        sortTicker:Cancel()
        sortTicker = nil
    end
    events:UnregisterEvent("BAG_UPDATE")
    events:UnregisterEvent("ITEM_LOCK_CHANGED")
    wipe(sortItems)
    wipe(seenSlots)
    wipe(touchedSlots)
    for i = #sortSlots, 1, -1 do
        slotPool[#slotPool + 1] = sortSlots[i]
        sortSlots[i] = nil
    end
    WipeLists(plan)
    WipeLists(held)
    plan.made = false
end

local function SortTick()
    local now = GetTime()
    if now - sortStart > SORT_TIMEOUT or sortRounds >= SORT_MAX_ROUNDS or InCombatLockdown() then
        StopSort()
        Rebuild()
        return
    end
    -- A round once the bags settle: Blizzard's sort started (or won't), nothing
    -- moved for a moment, and no item is locked (every move confirmed).
    if not sortSawChange and now - sortStart < SORT_NO_CHANGE_WAIT then return end
    if now - lastBagChange < SORT_QUIET_TIME then return end
    if CursorHasItem() or AnyItemLocked() then return end

    sortRounds = sortRounds + 1
    if not (ns.db.closeGaps and CloseGapsRound or SortRound)() then
        StopSort()
    end
    -- The highlights for the new places (the round scanned the bags again).
    Rebuild()
    lastBagChange = now
end

local function OnBagsSorted()
    if not ns.db or ns.db.sortCorner == SORT_OFF or InCombatLockdown() then return end
    StopSort()
    sortStart, sortRounds, lastBagChange, sortSawChange = GetTime(), 0, GetTime(), false
    -- These fire all the time while items move, so only while sorting.
    events:RegisterEvent("BAG_UPDATE")
    events:RegisterEvent("ITEM_LOCK_CHANGED")
    sortTicker = C_Timer.NewTicker(SORT_TICK, SortTick)
end

if C_Container.SortBags then
    hooksecurefunc(C_Container, "SortBags", OnBagsSorted)
end

ns.NoteBagChange, ns.UpdateVisualIndex = NoteBagChange, UpdateVisualIndex
