-- LootTriage's loot coins: with full bags, each loot item is paired with a bag
-- item to delete for it (the most valuable loot with your cheapest item, and
-- so on), and loot worth more than its pair gets a gold coin. The bags
-- highlight every pair. Quest items always count as worth more. A delete
-- button on the loot window can delete those bag items.
--
-- Sections: Room and worth, Pairing, Coins, Deleting, Refreshing.
local _, ns = ...

local GetContainerItemInfo = C_Container.GetContainerItemInfo
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerNumFreeSlots = C_Container.GetContainerNumFreeSlots
local PickupContainerItem = C_Container.PickupContainerItem
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local After = C_Timer.After
local GetTime = GetTime
local ipairs, pairs, wipe = ipairs, pairs, wipe
local sort, huge = table.sort, math.huge
local LOOT_SLOT_ITEM = (Enum.LootSlotType and Enum.LootSlotType.Item) or 1
local GetItemFamily = (C_Item and C_Item.GetItemFamily) or GetItemFamily
local band = bit and bit.band

local SHOW_OFF, LAST_BAG, LAST_ANY_BAG = ns.SHOW_OFF, ns.LAST_BAG, ns.LAST_ANY_BAG
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
-- them, or in a profession bag that takes it. Free slots in the reagent bag's
-- slot never count: Forever puts profession bags there that take far less.
local function HasRoomElsewhere(itemID, quantity, maxStack)
    local itemFamily = GetItemFamily and GetItemFamily(itemID) or 0
    for bag = 0, LAST_BAG do
        local free, family = GetContainerNumFreeSlots(bag)
        if (free or 0) > 0 and (family or 0) ~= 0 and band and itemFamily ~= 0 and band(itemFamily, family) ~= 0 then
            return true
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
    local _, _, quality, _, _, _, _, maxStack, _, _, sellPrice, _, _, bindType = GetItemInfo(itemID)
    if not maxStack then
        WaitForItemInfo(itemID)
        if isQuestItem then return "quest", 0 end
        return "pending"
    end
    -- Loot that binds when picked up (1) and gray loot go by the vendor's price.
    sellPrice = ItemWorth(link, ExactSellPrice(link, sellPrice), bindType == 1 or quality == 0)
    if HasRoomElsewhere(itemID, quantity, maxStack) then
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

-- Plumber's Loot Window, which replaces Blizzard's: its rows.
local function PlumberRows()
    local window = PlumberLootWindow
    local rows = type(window) == "table" and window.activeFrames
    return type(rows) == "table" and rows or nil
end

-- XLoot's loot window, which replaces Blizzard's too: the rows it shows now.
local function XLootRows()
    local window = XLootFrame
    local rows = type(window) == "table" and window.slots
    return type(rows) == "table" and rows or nil
end

local function ForEachRow(rows, fn)
    if rows then
        for _, row in ipairs(rows) do fn(row) end
    end
end

-- fn(row) for each row of the loot window: Blizzard's scroll list, older
-- clients' numbered buttons, Plumber's or XLoot's rows.
local function ForEachLootButton(fn)
    if LootFrame:IsShown() then
        if LootFrame.ScrollBox and LootFrame.ScrollBox.ForEachFrame then
            LootFrame.ScrollBox:ForEachFrame(fn)
        else
            for i = 1, (LOOTFRAME_NUMBUTTONS or 4) do
                local button = _G["LootButton" .. i]
                if button and button:IsShown() then fn(button) end
            end
        end
    end
    ForEachRow(PlumberRows(), fn)
    ForEachRow(XLootRows(), fn)
end

-- The loot slot a row shows (a Plumber row keeps it in its data, an XLoot
-- row in its slot field).
local function LootSlotOf(button)
    if button.GetSlotIndex then return button:GetSlotIndex() end
    local plumber = PlumberLootWindow
    if plumber and button.lootFrame == plumber then
        local data = button.data
        return type(data) == "table" and data.slotIndex or nil
    end
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
        -- Plumber's and XLoot's icons are frames of their own, drawn over their rows.
        local icon = button.IconFrame or button.frame_item
        mark = (icon or button):CreateTexture(nil, "OVERLAY", nil, 7)
        mark:SetSize(18, 18)
        mark:SetPoint("CENTER", button.Item or icon or button, "TOPRIGHT", -4, -4)
        mark:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon") -- the money display's gold coin
        lootMarks[button] = mark
    end
    mark:Show()
end

local function HideLootMarks()
    for _, mark in pairs(lootMarks) do mark:Hide() end
end

---------------------------------------------------------------------------
-- Deleting
---------------------------------------------------------------------------
-- With full bags, the delete button on the loot window's title bar, and taking
-- loot when that's turned on, delete the bag item numbered for loot worth
-- more. The game only lets addon code delete items on a click, out of combat.

local deleteButton

-- The bag item to delete next: the lowest number whose loot is worth more.
local function NextToDelete()
    if not loot.session or FreeSlots() > 0 then return end
    local best
    for _, pair in pairs(lootPairs) do
        if pair.worth and pair.rank and PairValid(pair) and (not best or pair.rank < best.rank) then
            best = pair
        end
    end
    return best
end

-- Deletes a pair's bag item if it's still the stack that was paired; true if it did.
local function DeletePairItem(pair)
    if InCombatLockdown() or CursorHasItem() or not PairValid(pair) then return false end
    local info = GetContainerItemInfo(pair.bag, pair.slot)
    if info.isLocked or (info.stackCount or 1) ~= pair.count then return false end
    PickupContainerItem(pair.bag, pair.slot)
    local kind, itemID = GetCursorInfo()
    if kind ~= "item" or itemID ~= pair.itemID then
        ClearCursor()
        return false
    end
    DeleteCursorItem()
    return true
end

-- The button's tooltip is the bag item it deletes. The line under it comes
-- from the item post-call in Tooltip.lua, so a rebuilt tooltip keeps it.
local function ShowDeleteTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    local pair = NextToDelete()
    if pair then
        GameTooltip:SetBagItem(pair.bag, pair.slot)
    else
        GameTooltip:SetText("Delete")
        GameTooltip:AddLine(InCombatLockdown() and "Items can't be deleted in combat."
            or "Nothing to delete: no loot here is worth more than what it would replace.", 1, 1, 1, true)
    end
    GameTooltip:Show()
end

-- What a click on the button does, for the bag item in its tooltip.
local function DeleteButtonLine(owner)
    if not deleteButton or owner ~= deleteButton then return end
    local pair = NextToDelete()
    if not pair then return end
    if InCombatLockdown() then return "Items can't be deleted in combat.", 1, 0.2, 0.2 end
    local number = ns.db.highlightMode ~= SHOW_OFF and (" (#%d in your bags)"):format(pair.rank) or ""
    return ("Click to delete this%s and make room for %s."):format(number,
        GetLootSlotLink(pair.lootSlot) or "better loot"), 0.2, 1, 0.2
end

local function OnDeleteClick(button)
    local pair = NextToDelete()
    if not pair then return end
    DeletePairItem(pair)
    ShowDeleteTooltip(button)
end

-- Blizzard's red delete button (character select's), a little smaller than
-- the close button, in the title bar's empty left corner.
local function CreateDeleteButton()
    local button = CreateFrame("Button") -- no parent: see GetOverlay in Bags.lua
    button:SetParent(LootFrame)
    button:SetSize(20, 20)
    button:SetPoint("TOPLEFT", LootFrame, "TOPLEFT", 6, -1)
    if LootFrame.ClosePanelButton then button:SetFrameLevel(LootFrame.ClosePanelButton:GetFrameLevel()) end
    button:SetNormalAtlas("128-RedButton-Delete")
    button:SetPushedAtlas("128-RedButton-Delete-Highlight")
    button:SetDisabledAtlas("128-RedButton-Delete-Disabled")
    button:SetHighlightAtlas("RedButton-Highlight", "ADD")
    button:SetScript("OnClick", OnDeleteClick)
    button:SetScript("OnEnter", ShowDeleteTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

local function UpdateDeleteButton()
    if not (ns.db.trashButton and loot.open and loot.session and LootFrame:IsShown()) then
        if deleteButton then deleteButton:Hide() end
        return
    end
    deleteButton = deleteButton or CreateDeleteButton()
    deleteButton:SetEnabled(NextToDelete() ~= nil)
    deleteButton:Show()
    if GameTooltip:IsOwned(deleteButton) then ShowDeleteTooltip(deleteButton) end
end

-- Double-clicking loot (its row in Blizzard's window) deletes its bag item
-- first, so the loot goes in that slot. PreClick runs before Blizzard's OnClick
-- takes the loot, which the window sets again for each row it fills. The first
-- click is the game's own, which can't take loot into full bags.
local DOUBLE_CLICK_SECONDS = 0.5
local hookedLootItems = {}
local lastClickSlot, lastClickTime = nil, 0

local function OnLootItemPreClick(item)
    if not ns.db.doubleClickLoot or IsModifiedClick() or FreeSlots() > 0 then return end
    local lootSlot = LootSlotOf(item:GetParent())
    local pair = loot.session and lootSlot and lootPairs[lootSlot]
    if not (pair and pair.worth and pair.rank and PairValid(pair)) then return end
    local now = GetTime()
    local second = lastClickSlot == lootSlot and now - lastClickTime <= DOUBLE_CLICK_SECONDS
    lastClickSlot, lastClickTime = lootSlot, now
    if second then DeletePairItem(pair) end
end

-- The loot list set up a row, also one it reuses while scrolling.
local function OnLootRowInitialized(_, button)
    if not ns.db then return end
    UpdateLootMark(button)
    local item = button.Item
    if item and not hookedLootItems[item] then
        hookedLootItems[item] = true
        item:HookScript("PreClick", OnLootItemPreClick)
    end
end

-- Plumber lays out its rows each time it fills them (the loot opening, a
-- failed auto loot, ...).
local function OnPlumberLayout()
    if ns.db then ForEachRow(PlumberRows(), UpdateLootMark) end
end

-- XLoot fills its rows in its window's Update.
local function OnXLootUpdate()
    if ns.db then ForEachRow(XLootRows(), UpdateLootMark) end
end

-- Once, when the loot window exists (Plumber and XLoot load after LootTriage).
local lootRowsHooked, plumberHooked, xlootHooked = false, false, false
local function HookLootRows()
    if not plumberHooked and type(PlumberLootWindow) == "table"
        and type(PlumberLootWindow.LayoutActiveFrames) == "function" then
        hooksecurefunc(PlumberLootWindow, "LayoutActiveFrames", OnPlumberLayout)
        plumberHooked = true
    end
    if not xlootHooked and type(XLootFrame) == "table" and type(XLootFrame.Update) == "function" then
        hooksecurefunc(XLootFrame, "Update", OnXLootUpdate)
        xlootHooked = true
    end
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

-- A loot addon that replaces Blizzard's window (Plumber's Loot Window) takes
-- the loot event from it: then there's no window to wait for.
local function BlizzardLootWindowInUse()
    return not LootFrame.IsEventRegistered or LootFrame:IsEventRegistered("LOOT_OPENED")
end

-- The pairing started (or started again when out of date), or kept up with
-- what was looted or deleted; then the coins.
local function RefreshLoot()
    lootQueued = false
    HideLootMarks()
    if not loot.open or (not ns.db.lootAdvice and ns.db.highlightMode == SHOW_OFF) then
        UpdateDeleteButton()
        return
    end
    if not LootFrame or (not LootFrame:IsShown() and BlizzardLootWindowInUse()) then
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
    UpdateDeleteButton()
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
    UpdateDeleteButton()
end

ns.OnLootOpened, ns.OnLootSlotCleared, ns.OnLootClosed, ns.QueueRefreshLoot = OnLootOpened, OnLootSlotCleared, OnLootClosed, QueueRefreshLoot
ns.HookLootRows, ns.OnOptionsChanged, ns.LootSlotOf = HookLootRows, OnOptionsChanged, LootSlotOf
ns.DeleteButtonLine = DeleteButtonLine
