-- LootTriage: looting with full bags, a gold coin marks the loot worth making
-- room for, and your bags number what to delete for it, cheapest first.
--
-- Files, in load order (they share through the addon table `ns`):
--   QuestItems.lua  items the original game's quests ask for (generated)
--   LootTriage.lua  settings, the bag scan, loading and events
--   Quests.lua      items quests need
--   Bags.lua        highlights, kept items and quest marks in the bags
--   Sorting.lua     junk to a corner after Blizzard's sort
--   Loot.lua        coins on loot when bags are full
--   Tooltip.lua     LootTriage's tooltip lines
--   WhatsNew.lua    the patch notes dialog
--   Settings.lua    the settings pages and /lt
--
-- Sections: Settings, Shared, Scanning, Loading.
local ADDON_NAME, ns = ...

local C_Container = C_Container
local GetContainerItemInfo = C_Container.GetContainerItemInfo
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerNumFreeSlots = C_Container.GetContainerNumFreeSlots
local GetContainerItemQuestInfo = C_Container.GetContainerItemQuestInfo
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local ipairs, pairs, wipe = ipairs, pairs, wipe
local sort, floor = table.sort, math.floor

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- Show highlights (highlightMode).
local SHOW_OFF, SHOW_LOOTING, SHOW_NEARLY_FULL, SHOW_ALWAYS = 0, 1, 2, 3
local NEARLY_FULL_SLOTS = 4 -- free slots or fewer

-- Junk after sorting (sortCorner).
local SORT_OFF, SORT_BOTTOM_RIGHT, SORT_TOP_LEFT = 0, 1, 2

-- Retail's interface numbers have six digits (120100), WoW Forever's five (16001).
local IS_RETAIL = (select(4, GetBuildInfo()) or 0) >= 100000

local defaults = {
    highlightMode = SHOW_LOOTING, -- when bag items are highlighted
    count = 5,              -- items highlighted outside looting
    maxQuality = IS_RETAIL and 2 or 1, -- 0 grays only, 1 and whites, 2 and greens
    keepConsumables = true, -- never highlighted: potions, food, scrolls...
    keepReagents = true,    -- crafting materials
    keepSpellReagents = true, -- Rune of Teleportation, Light Feather...
    keepTools = true,       -- profession tools, fishing poles
    keepRecipes = true,
    keepEquipment = false,  -- weapons and armor
    keepQuestItems = false, -- items for quests in your log
    keepUnstartedQuestItems = false, -- items for quests not picked up yet
    keepRepeatableQuestItems = false,
    questMark = false,      -- a quest "!" on bag items a quest keeps
    skipGrayQuests = false,
    questLevelsAbove = 60,  -- quests up to this many levels above yours (60: all)
    sortCorner = SORT_BOTTOM_RIGHT, -- where junk goes after a bag sort
    closeGaps = false,      -- the other items close up after a sort
    lootAdvice = true,      -- coins on loot when bags are full
    auctionPrices = false,  -- the auction price when it's above the vendor's
    auctionMaxAge = 14,     -- days
    auctionCutPercent = 0,
    keep = {},              -- [itemID] = true: kept, never suggested
    keepClick = 3,          -- the click that keeps a bag item (KEEP_CLICKS, 0 off)
}

-- Clicks that keep a bag item.
local KEEP_CLICKS = {
    [1] = { name = "Ctrl+Left-click", ctrl = true, button = "LeftButton" },
    [2] = { name = "Ctrl+Right-click", ctrl = true, button = "RightButton" },
    [3] = { name = "Alt+Left-click", alt = true, button = "LeftButton" },
    [4] = { name = "Alt+Right-click", alt = true, button = "RightButton" },
}
local KEEP_CLICK_OFF = 0

-- Tools the game doesn't flag as tools.
local TOOL_ITEMS = {
    [4471] = true,  -- Flint and Tinder
    [2901] = true,  -- Mining Pick
    [5956] = true,  -- Blacksmith Hammer
    [7005] = true,  -- Skinning Knife
    [6219] = true,  -- Arclight Spanner
    [10498] = true, -- Gyromatic Micro-Adjustor
    [9149] = true,  -- Philosopher's Stone
    [6218] = true,  -- Runed Copper Rod
    [6339] = true,  -- Runed Silver Rod
    [11130] = true, -- Runed Golden Rod
    [11145] = true, -- Runed Truesilver Rod
    [16207] = true, -- Runed Arcanite Rod
}

-- Item classes (Enum.ItemClass) and subclasses.
local CLASS_CONSUMABLE = 0
local CLASS_WEAPON = 2
local CLASS_ARMOR = 4
local CLASS_REAGENT = 5
local CLASS_TRADEGOODS = 7
local CLASS_RECIPE = 9
local CLASS_MISC = 15
local CLASS_PROFESSION = 19
local SUBCLASS_FISHING_POLE = 20
local SUBCLASS_MISC_REAGENT = 1 -- spell reagents

local LAST_BAG = NUM_BAG_SLOTS or 4
local REAGENT_BAG = Enum.BagIndex and Enum.BagIndex.ReagentBag
local LAST_ANY_BAG = (REAGENT_BAG and REAGENT_BAG > LAST_BAG) and REAGENT_BAG or LAST_BAG
local RequestLoadItemData = C_Item and C_Item.RequestLoadItemDataByID

---------------------------------------------------------------------------
-- Shared
---------------------------------------------------------------------------

local db -- LootTriageDB, once it's loaded
local events = CreateFrame("Frame")

-- The loot window, kept by Loot.lua. open: LOOT_OPENED to LOOT_CLOSED (the
-- window fades out after closing, so it can't tell). session: looting with full
-- bags, the bags showing each loot item's pair instead of the cheapest items.
local loot = { open = false, session = false }
-- [lootSlot] = the bag item to delete for that loot (see Loot.lua).
local lootPairs = {}

local candidates = {}  -- deletable bag items, the first to delete first
local entryPool = {}   -- spare candidate tables
local normalBags = {}
local pendingInfo = false

-- A bag slot as one number, so no strings are built.
local function SlotKey(bag, slot)
    return bag * 1000 + slot
end

local function Print(msg)
    print("|cff33ff99LootTriage|r: " .. msg)
end

local function MoneyText(copper)
    if copper <= 0 then return "no vendor value" end
    if GetMoneyString then return GetMoneyString(copper, true) end
    return copper .. "c"
end

local function ValueText(e)
    return MoneyText(e.value) .. (e.auction and " at auction" or "")
end

local function ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- Your regular bags (family 0): room in a profession or reagent bag doesn't
-- help when they're full. The table is reused.
local function NormalBags()
    wipe(normalBags)
    for bag = 0, LAST_BAG do
        local _, family = GetContainerNumFreeSlots(bag)
        if (family or 0) == 0 and GetContainerNumSlots(bag) > 0 then
            normalBags[#normalBags + 1] = bag
        end
    end
    return normalBags
end

local function FreeSlots()
    local free = 0
    for bag = 0, LAST_BAG do
        local n, family = GetContainerNumFreeSlots(bag)
        if (family or 0) == 0 then free = free + (n or 0) end
    end
    return free
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------
-- Which bag items may be suggested for deletion, what each is worth, and in
-- what order.

-- A white or better item of a kind the settings keep.
local function IsProtected(itemID, classID, subclassID, isCraftingReagent)
    if db.keepReagents and (isCraftingReagent or classID == CLASS_REAGENT or classID == CLASS_TRADEGOODS) then
        return true
    end
    if db.keepSpellReagents and classID == CLASS_MISC and subclassID == SUBCLASS_MISC_REAGENT then return true end
    if db.keepTools and (TOOL_ITEMS[itemID] or classID == CLASS_PROFESSION
            or (classID == CLASS_WEAPON and subclassID == SUBCLASS_FISHING_POLE)) then
        return true
    end
    if db.keepConsumables and classID == CLASS_CONSUMABLE then return true end
    if db.keepRecipes and classID == CLASS_RECIPE then return true end
    if db.keepEquipment and (classID == CLASS_WEAPON or classID == CLASS_ARMOR) then return true end
    return false
end

-- Item info not loaded yet: ask for it, and look again when it arrives.
local function WaitForItemInfo(itemID)
    if RequestLoadItemData then RequestLoadItemData(itemID) end
    if not pendingInfo then
        pendingInfo = true
        events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    end
end

-- Retail: one item comes at many item levels, and its own link has its price.
local function ExactSellPrice(link, sellPrice)
    if IS_RETAIL and link then
        return select(11, GetItemInfo(link)) or sellPrice
    end
    return sellPrice
end

-- Auction prices: Auctionator's API for other addons (Auctionator.API.v1, as in
-- Auctionator 340) gives the last price seen for one of an item, in copper, and
-- its age in days. Its calls error on bad arguments, hence the pcall. Without
-- Auctionator, Blackthornes Tradeskills' BlackthornesTS_API (version 1) gives
-- the same in copper and seconds; its age is only for its own scans, so prices
-- it takes from elsewhere have none and don't count. Answers are kept until the
-- auction house closes, the only place prices change.
local auctionator, blackthornes, priceAddon
local auctionCache = {} -- [link] = copper, false: no price
local auctionAges = {}  -- [link] = days, false: not known

local function AskAuctionator(call, link)
    local ok, result = pcall(auctionator[call], ADDON_NAME, link)
    if ok and type(result) == "number" then return result end
end

local function AskBlackthornes(call, link)
    local ok, result = pcall(blackthornes[call], link)
    if ok and type(result) == "number" then return result end
end

-- The auction price for one, less the cut; nil without a recent one.
local function AuctionPrice(link)
    local price = auctionCache[link]
    if price == nil then
        if auctionator then
            price = AskAuctionator("GetAuctionPriceByItemLink", link) or false
            auctionAges[link] = price and AskAuctionator("GetAuctionAgeByItemLink", link) or false
        else
            price = AskBlackthornes("GetPrice", link) or false
            local seconds = price and AskBlackthornes("GetPriceAge", link)
            auctionAges[link] = seconds and floor(seconds / 86400) or false
        end
        auctionCache[link] = price
    end
    local age = auctionAges[link]
    if not price or not age or age > db.auctionMaxAge then return end
    local cut = db.auctionCutPercent
    if cut > 0 then price = floor(price * (100 - cut) / 100) end
    return price
end

-- One of an item: the vendor's price, or the auction price when higher (then
-- true too). vendorOnly: soulbound or gray items, always at the vendor's price.
local function ItemWorth(link, sellPrice, vendorOnly)
    sellPrice = sellPrice or 0
    if db.auctionPrices and priceAddon and link and not vendorOnly then
        local price = AuctionPrice(link)
        if price and price > sellPrice then return price, true end
    end
    return sellPrice, false
end

-- A bag slot's item as a candidate { bag, slot, itemID, quality, value, count,
-- link, auction }, or nil when it's kept.
local function EvaluateSlot(bag, slot)
    local info = GetContainerItemInfo(bag, slot)
    if not info then return end
    local itemID, quality = info.itemID, info.quality
    if not itemID or not quality or quality > db.maxQuality or db.keep[itemID] then return end

    local quest = GetContainerItemQuestInfo(bag, slot)
    if quest and (quest.isQuestItem or quest.questID) then return end

    local name, _, _, _, _, _, _, _, _, _, sellPrice, classID, subclassID, _, _, _, isCraftingReagent =
        GetItemInfo(itemID)
    if sellPrice == nil then
        WaitForItemInfo(itemID)
        return
    end
    if ns.NeededForQuest(itemID, name) then return end
    if quality > 0 then
        -- Whites and up without a vendor price are special (hearthstone, keys).
        if info.hasNoValue or sellPrice == 0 then return end
        if IsProtected(itemID, classID, subclassID, isCraftingReagent) then return end
    end
    -- Gear in an equipment set is kept. On Retail its price is its item level's.
    if classID == CLASS_WEAPON or classID == CLASS_ARMOR then
        local InEquipmentSet = C_Container.GetContainerItemEquipmentSetInfo
        if InEquipmentSet and InEquipmentSet(bag, slot) then return end
        sellPrice = ExactSellPrice(info.hyperlink, sellPrice)
    end

    local n = #entryPool
    local e = entryPool[n]
    if e then entryPool[n] = nil else e = {} end
    local count = info.stackCount or 1
    local worth, auction = ItemWorth(info.hyperlink, sellPrice, info.isBound or quality == 0)
    e.bag, e.slot, e.itemID, e.quality = bag, slot, itemID, quality
    e.value, e.count, e.link, e.auction = worth * count, count, info.hyperlink, auction
    return e
end

-- The cheapest stack first, then the lower quality. Item and stack size come
-- before the place, so the order holds while items move. Identical stacks go by
-- their place on screen from the sort corner, worked out once a scan, if needed.
local visualIndex = {}   -- [slotKey] = 1 for the corner slot, 2 next... (Sorting.lua)
local visualReady = false

local function ComparePriority(a, b)
    if a.value ~= b.value then return a.value < b.value end
    if a.quality ~= b.quality then return a.quality < b.quality end
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    if a.count ~= b.count then return a.count < b.count end
    if not visualReady then
        visualReady = true
        ns.UpdateVisualIndex()
    end
    local va, vb = visualIndex[SlotKey(a.bag, a.slot)], visualIndex[SlotKey(b.bag, b.slot)]
    if va and vb then return va < vb end
    -- Top left runs against the bag numbers: items on screen first, or the
    -- order would contradict itself.
    if db.sortCorner == SORT_TOP_LEFT and (va or vb) then return va ~= nil end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
end

-- Fills `candidates` again. Its tables are reused, so ApplyHighlights has to
-- follow: the highlights point at them.
local function ScanBags()
    for i = #candidates, 1, -1 do
        entryPool[#entryPool + 1] = candidates[i]
        candidates[i] = nil
    end
    for _, bag in ipairs(NormalBags()) do
        for slot = 1, GetContainerNumSlots(bag) do
            local e = EvaluateSlot(bag, slot)
            if e then candidates[#candidates + 1] = e end
        end
    end
    visualReady = false
    sort(candidates, ComparePriority)
end

-- For the other files.
ns.IS_RETAIL, ns.defaults, ns.KEEP_CLICKS, ns.KEEP_CLICK_OFF = IS_RETAIL, defaults, KEEP_CLICKS, KEEP_CLICK_OFF
ns.SHOW_OFF, ns.SHOW_LOOTING, ns.SHOW_NEARLY_FULL, ns.SHOW_ALWAYS = SHOW_OFF, SHOW_LOOTING, SHOW_NEARLY_FULL, SHOW_ALWAYS
ns.NEARLY_FULL_SLOTS, ns.SORT_OFF, ns.SORT_BOTTOM_RIGHT, ns.SORT_TOP_LEFT = NEARLY_FULL_SLOTS, SORT_OFF, SORT_BOTTOM_RIGHT, SORT_TOP_LEFT
ns.LAST_BAG, ns.REAGENT_BAG, ns.LAST_ANY_BAG = LAST_BAG, REAGENT_BAG, LAST_ANY_BAG
ns.events, ns.loot, ns.lootPairs, ns.candidates, ns.visualIndex = events, loot, lootPairs, candidates, visualIndex
ns.SlotKey, ns.Print, ns.ValueText, ns.ItemIDFromLink = SlotKey, Print, ValueText, ItemIDFromLink
ns.NormalBags, ns.FreeSlots, ns.WaitForItemInfo = NormalBags, FreeSlots, WaitForItemInfo
ns.ExactSellPrice, ns.ItemWorth, ns.ScanBags = ExactSellPrice, ItemWorth, ScanBags

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------

local function OnAddonLoaded()
    LootTriageDB = LootTriageDB or {}
    -- Sorting used to be an on/off checkbox (sortAfter): off stays off.
    if LootTriageDB.sortAfter == false and LootTriageDB.sortCorner == nil then
        LootTriageDB.sortCorner = SORT_OFF
    end
    -- Items for quests used to cover quests not picked up yet too.
    if LootTriageDB.keepUnstartedQuestItems == nil and LootTriageDB.keepQuestItems ~= nil then
        LootTriageDB.keepUnstartedQuestItems = LootTriageDB.keepQuestItems
    end
    -- Settings that are gone are dropped, new ones filled in.
    for k in pairs(LootTriageDB) do
        if defaults[k] == nil then LootTriageDB[k] = nil end
    end
    for k, v in pairs(defaults) do
        if LootTriageDB[k] == nil then
            LootTriageDB[k] = type(v) == "table" and {} or v
        end
    end
    db = LootTriageDB
    ns.db = db

    -- A price addon, if installed (the .toc's OptionalDeps loads it first):
    -- Auctionator, else Blackthornes Tradeskills.
    local api = type(Auctionator) == "table" and type(Auctionator.API) == "table" and Auctionator.API.v1
    local bts = BlackthornesTS_API
    if type(api) == "table" then
        auctionator = api
    elseif type(bts) == "table" and type(bts.GetPrice) == "function" and type(bts.GetPriceAge) == "function" then
        blackthornes = bts
    end
    if auctionator or blackthornes then
        priceAddon = true
        ns.priceAddon = true
        events:RegisterEvent("AUCTION_HOUSE_CLOSED")
    end

    ns.CollectContainerFrames()
    ns.HookContainerFrames()
    ns.HookLootRows()
    if Settings and Settings.RegisterVerticalLayoutCategory then
        local ok, err = pcall(ns.RegisterSettings)
        if not ok then
            Print("couldn't create the settings panel: " .. tostring(err))
        end
    end

    events:UnregisterEvent("ADDON_LOADED")
    events:RegisterEvent("BAG_UPDATE_DELAYED")
    events:RegisterEvent("LOOT_OPENED")
    events:RegisterEvent("LOOT_SLOT_CLEARED")
    events:RegisterEvent("LOOT_SLOT_CHANGED")
    events:RegisterEvent("LOOT_CLOSED")
    events:RegisterEvent("QUEST_LOG_UPDATE")
    events:RegisterEvent("PLAYER_LEVEL_UP")
end

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "BAG_UPDATE" or event == "ITEM_LOCK_CHANGED" then
        ns.NoteBagChange()
    elseif event == "BAG_UPDATE_DELAYED" then
        if ns.BagsOpen() then ns.QueueRebuild() end
        if loot.open then ns.QueueRefreshLoot() end
    elseif event == "LOOT_OPENED" then
        ns.HookLootRows()
        ns.OnLootOpened()
    elseif event == "LOOT_SLOT_CHANGED" then
        ns.QueueRefreshLoot()
    elseif event == "LOOT_SLOT_CLEARED" then
        ns.OnLootSlotCleared(arg1)
    elseif event == "LOOT_CLOSED" then
        ns.OnLootClosed()
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_DATA_LOAD_RESULT" then
        ns.OnQuestLogUpdate(event)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- The price addon may have new prices.
        wipe(auctionCache)
        if db.auctionPrices and ns.BagsOpen() then ns.QueueRebuild() end
    elseif event == "PLAYER_LEVEL_UP" then
        ns.OnLevelUp(arg1)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        pendingInfo = false
        events:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
        ns.OnOptionsChanged()
    elseif event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- After an update, a /reload only loads the files the old .toc listed:
        -- stay off until the game is restarted.
        if not (ns.NeededForQuest and ns.QueueRebuild and ns.UpdateVisualIndex and ns.OnLootOpened
                and ns.AddTooltipLine and ns.ShowWhatsNew and ns.RegisterSettings) then
            events:UnregisterAllEvents()
            return
        end
        OnAddonLoaded()
    end
end)
