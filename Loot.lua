-- LootTriage's loot coins: with full bags, each loot item is paired with a bag
-- item to delete for it (the most valuable loot with your cheapest item, and
-- so on), and loot worth more than its pair gets a gold coin. The bags
-- highlight every pair. Quest items always count as worth more.
--
-- Sections: Room and worth, Pairing, Coins, Refreshing.
local _, ns = ...

local GetContainerItemInfo = C_Container.GetContainerItemInfo
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerNumFreeSlots = C_Container.GetContainerNumFreeSlots
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local After = C_Timer.After
local ipairs, pairs, wipe = ipairs, pairs, wipe
local sort, huge = table.sort, math.huge
local LOOT_SLOT_ITEM = (Enum.LootSlotType and Enum.LootSlotType.Item) or 1
local GetItemFamily = (C_Item and C_Item.GetItemFamily) or GetItemFamily
local band = bit and bit.band

local SHOW_OFF, REAGENT_BAG, LAST_ANY_BAG = ns.SHOW_OFF, ns.REAGENT_BAG, ns.LAST_ANY_BAG
local events, loot, lootPairs, candidates = ns.events, ns.loot, ns.lootPairs, ns.candidates
local SlotKey, FreeSlots, ItemIDFromLink, ScanBags = ns.SlotKey, ns.FreeSlots, ns.ItemIDFromLink, ns.ScanBags
local WaitForItemInfo, ExactSellPrice, ItemWorth = ns.WaitForItemInfo, ns.ExactSellPrice, ns.ItemWorth
local PairValid, ApplyHighlights, QueueRebuild = ns.PairValid, ns.ApplyHighlights, ns.QueueRebuild

---------------------------------------------------------------------------
-- Room and worth
---------------------------------------------------------------------------

local lootRestart = false -- pair again on the next refresh

-- A paired stack changed size, so its value and the pairing are out of date.
local function AnyPairStale()
    for _, pair in pairs(lootPairs) do
        if pair.bag then
            local info = GetContainerItemInfo(pair.bag, pair.slot)
            if info and info.itemID == pair.itemID and (info.stackCount or 1) ~= pair.count then
                return true
            end
        end
    end
    return false
end

local lootMarks = {}   -- [loot row] = coin texture
local lootItems = {}   -- the loot to pair, reused as its pairs
local usedSlots, brokenPairs = {}, {}

-- Every stack in the bags, counted once a loot update: count[itemID] stacks
-- holding items[itemID] items.
local stacks = { count = {}, items = {}, counted = false }

-- Whether loot fits without a free regular slot: on stacks with room between
-- them, in a profession bag that takes it, or (a crafting reagent) the reagent bag.
local function HasRoomElsewhere(itemID, quantity, maxStack, isCraftingReagent)
    local itemFamily = GetItemFamily and GetItemFamily(itemID) or 0
    for bag = 0, LAST_ANY_BAG do
        local free, family = GetContainerNumFreeSlots(bag)
        if (free or 0) > 0 then
            if bag == REAGENT_BAG then
                if isCraftingReagent then return true end
            elseif (family or 0) ~= 0 and band and itemFamily ~= 0 and band(itemFamily, family) ~= 0 then
                return true
            end
        end
    end
    if maxStack > 1 then
        if not stacks.counted then
            wipe(stacks.count)
            wipe(stacks.items)
            for bag = 0, LAST_ANY_BAG do
                for slot = 1, GetContainerNumSlots(bag) do
                    local info = GetContainerItemInfo(bag, slot)
                    local id = info and info.itemID
                    if id then
                        stacks.count[id] = (stacks.count[id] or 0) + 1
                        stacks.items[id] = (stacks.items[id] or 0) + (info.stackCount or 1)
                    end
                end
            end
            stacks.counted = true
        end
        -- Loot fills up every stack with room, not just one.
        local n = stacks.count[itemID]
        if n and n * maxStack - stacks.items[itemID] >= quantity then return true end
    end
    return false
end

-- A loot slot's kind ("fits", "quest" or "item") and total value, or "pending"
-- while the game hasn't described it yet (it's looked at again shortly).
local function EvaluateLoot(lootSlot)
    if GetLootSlotType(lootSlot) ~= LOOT_SLOT_ITEM then return end
    local link = GetLootSlotLink(lootSlot)
    local itemID = ItemIDFromLink(link)
    if not itemID then return "pending" end

    local _, _, quantity, _, _, _, isQuestItem = GetLootSlotInfo(lootSlot)
    quantity = quantity or 1
    local _, _, quality, _, _, _, _, maxStack, _, _, sellPrice, _, _, bindType, _, _, isCraftingReagent = GetItemInfo(itemID)
    if not maxStack then
        WaitForItemInfo(itemID)
        if isQuestItem then return "quest", 0 end
        return "pending"
    end
    -- Loot that binds when picked up (1) and gray loot go by the vendor's price.
    sellPrice = ItemWorth(link, ExactSellPrice(link, sellPrice), bindType == 1 or quality == 0)
    if HasRoomElsewhere(itemID, quantity, maxStack, isCraftingReagent) then
        return "fits", isQuestItem and huge or (sellPrice or 0) * quantity
    end
    if isQuestItem then return "quest", 0 end
    return "item", (sellPrice or 0) * quantity
end

---------------------------------------------------------------------------
-- Pairing
---------------------------------------------------------------------------

local function ByLootValue(a, b)
    return a.lootValue > b.lootValue
end

-- worth: the loot is worth more than the bag item it replaces (a coin).
local function AssignPair(pair, e)
    pair.bag, pair.slot, pair.itemID, pair.count = e.bag, e.slot, e.itemID, e.count
    pair.link, pair.value, pair.auction = e.link, e.value, e.auction
    pair.worth = e.value < pair.lootValue
end

local lootIncomplete = false -- some loot wasn't described yet: look again shortly

-- Pairs the loot, the most valuable first. Redone while looting with free
-- slots, the most valuable loot takes those first.
local function StartLootSession()
    loot.session = true
    lootRestart = false
    lootIncomplete = false
    stacks.counted = false
    wipe(lootPairs)
    ScanBags()
    local free = FreeSlots()

    local n = 0
    for lootSlot = 1, GetNumLootItems() do
        local kind, value = EvaluateLoot(lootSlot)
        if kind == "pending" then
            lootIncomplete = true
        elseif kind == "fits" then
            -- Nothing to delete for it, but other loot may take its room first
            -- (UpdateFittingLoot pairs it then).
            lootPairs[lootSlot] = { lootSlot = lootSlot, lootValue = value, fits = true, worth = false }
        elseif kind == "quest" or kind == "item" then
            n = n + 1
            local item = lootItems[n] or {}
            lootItems[n] = item
            item.lootSlot, item.lootValue = lootSlot, (kind == "quest") and huge or value
        end
    end
    for i = #lootItems, n + 1, -1 do lootItems[i] = nil end
    sort(lootItems, ByLootValue)

    for i, pair in ipairs(lootItems) do
        pair.fits = nil
        if i <= free then
            pair.bag, pair.rank, pair.worth = nil, nil, true
        else
            local e = candidates[i - free]
            if not e then break end
            pair.rank = i - free
            AssignPair(pair, e)
        end
        lootPairs[pair.lootSlot] = pair
    end
end

-- Bags full again with some paired items gone (say one was deleted and other
-- loot took its slot): that loot gets the next cheapest bag item not paired yet.
local function RepairLootPairs()
    wipe(usedSlots)
    wipe(brokenPairs)
    local maxRank = 0
    for _, pair in pairs(lootPairs) do
        if PairValid(pair) then
            usedSlots[SlotKey(pair.bag, pair.slot)] = true
        elseif not pair.fits then
            brokenPairs[#brokenPairs + 1] = pair
        end
        if pair.rank and pair.rank > maxRank then maxRank = pair.rank end
    end
    if #brokenPairs == 0 then return end

    ScanBags()
    sort(brokenPairs, ByLootValue)
    local nextCandidate = 1
    for _, pair in ipairs(brokenPairs) do
        local found
        while nextCandidate <= #candidates do
            local e = candidates[nextCandidate]
            nextCandidate = nextCandidate + 1
            if not usedSlots[SlotKey(e.bag, e.slot)] then
                found = e
                break
            end
        end
        if found then
            if not pair.rank then
                -- Its free slot was used up: numbered after the others.
                maxRank = maxRank + 1
                pair.rank = maxRank
            end
            AssignPair(pair, found)
            usedSlots[SlotKey(found.bag, found.slot)] = true
        else
            lootPairs[pair.lootSlot] = nil
        end
    end
    wipe(brokenPairs)
end

-- Loot that fits now (on a stack or in a profession bag) needs nothing deleted:
-- its bag item goes and its coin stays, until it doesn't fit again.
local function UpdateFittingLoot()
    stacks.counted = false
    for lootSlot, pair in pairs(lootPairs) do
        local kind = EvaluateLoot(lootSlot)
        local fits = kind == "fits"
        if kind == "pending" then
            -- Not known yet: left as it is.
        elseif fits and not pair.fits then
            pair.fits, pair.bag, pair.worth = true, nil, true
        elseif not fits and pair.fits then
            pair.fits = nil -- RepairLootPairs gives it a bag item again
        end
    end
end

---------------------------------------------------------------------------
-- Coins
---------------------------------------------------------------------------

-- fn(row) for each row of Blizzard's loot window: its scroll list, or older
-- clients' numbered buttons.
local function ForEachLootButton(fn)
    if LootFrame.ScrollBox and LootFrame.ScrollBox.ForEachFrame then
        LootFrame.ScrollBox:ForEachFrame(fn)
    else
        for i = 1, (LOOTFRAME_NUMBUTTONS or 4) do
            local button = _G["LootButton" .. i]
            if button and button:IsShown() then fn(button) end
        end
    end
end

-- The loot slot a row shows.
local function LootSlotOf(button)
    if button.GetSlotIndex then return button:GetSlotIndex() end
    return button.slot
end

-- A row's coin, for whichever loot slot it shows now (rows are reused as the
-- list scrolls).
local function UpdateLootMark(button)
    local lootSlot = LootSlotOf(button)
    local pair = loot.session and ns.db.lootAdvice and lootSlot and lootPairs[lootSlot]
    local mark = lootMarks[button]
    if not pair or not pair.worth then
        if mark then mark:Hide() end
        return
    end
    if not mark then
        mark = button:CreateTexture(nil, "OVERLAY", nil, 7)
        mark:SetSize(18, 18)
        mark:SetPoint("CENTER", button.Item or button, "TOPRIGHT", -4, -4)
        mark:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon") -- the money display's gold coin
        lootMarks[button] = mark
    end
    mark:Show()
end

local function HideLootMarks()
    for _, mark in pairs(lootMarks) do mark:Hide() end
end

-- The loot list set up a row, also one it reuses while scrolling.
local function OnLootRowInitialized(_, button)
    if ns.db then UpdateLootMark(button) end
end

-- Once, when the loot window exists.
local lootRowsHooked = false
local function HookLootRows()
    if lootRowsHooked or not LootFrame or not LootFrame.ScrollBox then return end
    if ScrollUtil and ScrollUtil.AddInitializedFrameCallback then
        ScrollUtil.AddInitializedFrameCallback(LootFrame.ScrollBox, OnLootRowInitialized, events, false)
        lootRowsHooked = true
    end
end

---------------------------------------------------------------------------
-- Refreshing
---------------------------------------------------------------------------
-- The coins stay until their loot is taken or the window closes, also after
-- you delete something to make room. The pairing is redone when settings or
-- the keep list change, item info arrives or a paired stack changes size.

local lootQueued = false
local QueueRefreshLoot

-- The loot window can show, or the game finish describing its items, a moment
-- after the loot event: looked at again every 0.1 seconds until it's ready.
local LOOT_RETRY_DELAY, LOOT_MAX_RETRIES = 0.1, 20
local lootRetries, lootRetryQueued = 0, false

local function RetryLoot()
    lootRetryQueued = false
    QueueRefreshLoot()
end

local function RetryLootSoon()
    if lootRetryQueued or lootRetries >= LOOT_MAX_RETRIES then return end
    lootRetries = lootRetries + 1
    lootRetryQueued = true
    After(LOOT_RETRY_DELAY, RetryLoot)
end

-- The pairing started (or started again when out of date), or kept up with
-- what was looted or deleted; then the coins.
local function RefreshLoot()
    lootQueued = false
    HideLootMarks()
    if not loot.open or (not ns.db.lootAdvice and ns.db.highlightMode == SHOW_OFF) then return end
    if not LootFrame or not LootFrame:IsShown() then
        if GetNumLootItems() > 0 then RetryLootSoon() end
        return
    end
    if not loot.session then
        if FreeSlots() > 0 then return end
        StartLootSession()
    elseif lootRestart or lootIncomplete or AnyPairStale() then
        StartLootSession()
    else
        UpdateFittingLoot()
        if FreeSlots() == 0 then RepairLootPairs() end
    end
    if lootIncomplete then RetryLootSoon() end
    ApplyHighlights()
    ForEachLootButton(UpdateLootMark)
end

-- The loot window fills in after loot events: on the next frame.
QueueRefreshLoot = function()
    if lootQueued then return end
    lootQueued = true
    After(0, RefreshLoot)
end

-- Each loot window gets a pairing of its own, even if the last one never closed.
local function OnLootOpened()
    loot.open = true
    if loot.session then lootRestart = true end
    lootRetries = 0
    QueueRefreshLoot()
end

-- Settings, the keep list or item info changed: the bags again, and a new
-- pairing while loot is open.
local function OnOptionsChanged()
    QueueRebuild()
    if loot.session then lootRestart = true end
    if loot.open then QueueRefreshLoot() end
end

-- The loot window reuses its rows when an item is taken, so the coins are
-- drawn again each time.
local function OnLootSlotCleared(lootSlot)
    lootPairs[lootSlot] = nil
    if loot.session then QueueRefreshLoot() end
end

-- The coins and pairs go, and the bags get their usual highlights back.
local function OnLootClosed()
    HideLootMarks()
    loot.open, lootRestart, lootIncomplete, lootRetries = false, false, false, LOOT_MAX_RETRIES
    if loot.session then
        loot.session = false
        wipe(lootPairs)
        ApplyHighlights()
    end
end

ns.OnLootOpened, ns.OnLootSlotCleared, ns.OnLootClosed, ns.QueueRefreshLoot = OnLootOpened, OnLootSlotCleared, OnLootClosed, QueueRefreshLoot
ns.HookLootRows, ns.OnOptionsChanged, ns.LootSlotOf = HookLootRows, OnOptionsChanged, LootSlotOf
