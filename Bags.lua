-- LootTriage in your bags: the highlight (a gold glow and a number) on what to
-- delete, the star on items you keep and the quest mark, on Blizzard's bag
-- buttons and on bag addons' buttons made from Blizzard's template.
--
-- Sections: Glow, Bag windows, Stars and quest marks, Highlights.
local _, ns = ...

local GetContainerItemInfo = C_Container.GetContainerItemInfo
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemQuestInfo = C_Container.GetContainerItemQuestInfo
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local After = C_Timer.After
local GetTime = GetTime
local ipairs, pairs, next, wipe = ipairs, pairs, next, wipe
local min, floor = math.min, math.floor

local IS_RETAIL, KEEP_CLICKS, LAST_ANY_BAG = ns.IS_RETAIL, ns.KEEP_CLICKS, ns.LAST_ANY_BAG
local SHOW_OFF, SHOW_NEARLY_FULL, SHOW_ALWAYS, NEARLY_FULL_SLOTS = ns.SHOW_OFF, ns.SHOW_NEARLY_FULL, ns.SHOW_ALWAYS, ns.NEARLY_FULL_SLOTS
local loot, lootPairs, candidates = ns.loot, ns.lootPairs, ns.candidates
local SlotKey, NormalBags, FreeSlots = ns.SlotKey, ns.NormalBags, ns.FreeSlots
local WaitForItemInfo, ScanBags = ns.WaitForItemInfo, ns.ScanBags
local NeededForQuest = ns.NeededForQuest

local rankBySlot = {}  -- [slotKey] = the number shown
local entryBySlot = {} -- [slotKey] = its candidate or loot pair, for the tooltip
local overlays = {}    -- [bag button] = its highlight
local containerFrames = {}

---------------------------------------------------------------------------
-- Glow
---------------------------------------------------------------------------
-- The proc glow action buttons get, built from the game's own textures (as
-- LibButtonGlow does): Blizzard's glow functions can taint the action bars.

local GOLD_R, GOLD_G, GOLD_B = 1, 0.82, 0
local PROC_GLOW = "Interface\\SpellActivationOverlay\\IconAlert"
local PROC_ANTS = "Interface\\SpellActivationOverlay\\IconAlertAnts"
local ANTS_FRAMES = 22                -- in the ants' flipbook
local ANTS_CELL = 48 / 256            -- a 48 pixel frame on the 256 pixel sheet
local ANTS_COLUMNS = 5
local ANTS_FRAME_TIME = 0.02          -- seconds a frame

-- Steps the ants' flipbook. OnUpdate only runs while the glow is shown.
local function AnimateProcGlow(o, elapsed)
    o.antsTime = (o.antsTime + elapsed) % (ANTS_FRAMES * ANTS_FRAME_TIME)
    local frame = floor(o.antsTime / ANTS_FRAME_TIME)
    if frame == o.antsFrame then return end
    o.antsFrame = frame
    local col, row = frame % ANTS_COLUMNS, floor(frame / ANTS_COLUMNS)
    o.ants:SetTexCoord(col * ANTS_CELL, (col + 1) * ANTS_CELL, row * ANTS_CELL, (row + 1) * ANTS_CELL)
end

local function GetOverlay(button)
    local o = overlays[button]
    if o then return o end

    -- 20% bigger than the button on each side, like the proc glow.
    local w, h = button:GetWidth() or 37, button:GetHeight() or 37
    if w == 0 then w, h = 37, 37 end
    -- Made with no parent, then parented: WoW Forever's gamepad UI hooks
    -- CreateFrame and rebuilds an open window's gamepad navigation from the
    -- addon's code, which gets SetPreferredGamepadInteractTarget blocked.
    o = CreateFrame("Frame")
    o:SetParent(button)
    o:SetPoint("TOPLEFT", button, "TOPLEFT", -w * 0.2, h * 0.2)
    o:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", w * 0.2, -h * 0.2)
    o:SetFrameLevel(button:GetFrameLevel() + 5)

    o.glow = o:CreateTexture(nil, "ARTWORK")
    o.glow:SetTexture(PROC_GLOW)
    o.glow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    o.glow:SetAllPoints()

    o.ants = o:CreateTexture(nil, "OVERLAY")
    o.ants:SetTexture(PROC_ANTS)
    o.ants:SetAllPoints()
    o.antsTime, o.antsFrame = 0, -1

    o.text = o:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    o.text:SetDrawLayer("OVERLAY", 7)
    o.text:SetPoint("TOPLEFT", button, "TOPLEFT", 3, -3)
    o.text:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
    -- A thick black outline and a shadow keep the gold number readable on the glow.
    local fontPath, fontSize = o.text:GetFont()
    if fontPath then o.text:SetFont(fontPath, fontSize, "THICKOUTLINE") end
    o.text:SetShadowColor(0, 0, 0, 1)
    o.text:SetShadowOffset(1, -1)

    overlays[button] = o
    return o
end

-- A still gold border, or with Animated glow the marching ants too (the only
-- time anything runs each frame).
local function ApplyGlowStyle(o)
    if ns.db.animatedGlow then
        if not o.animated then
            o.ants:Show()
            o:SetScript("OnUpdate", AnimateProcGlow)
            o.animated = true
        end
    elseif o.animated ~= false then
        o.ants:Hide()
        o:SetScript("OnUpdate", nil)
        o.animated = false
    end
end

---------------------------------------------------------------------------
-- Bag windows
---------------------------------------------------------------------------
-- Blizzard's, and bag addons' (Bagnon, EllesmereUI, AdiBags, BetterBags...):
-- most make their item buttons from Blizzard's bag button template, which
-- knows its bag and slot, so those get highlights too. Sorting only uses
-- Blizzard's windows: bag addons lay items out their own way.

-- The combined bag window, and one per bag.
local function CollectContainerFrames()
    if ContainerFrameCombinedBags then containerFrames[#containerFrames + 1] = ContainerFrameCombinedBags end
    for i = 1, (NUM_CONTAINER_FRAMES or 13) do
        local f = _G["ContainerFrame" .. i]
        if f then containerFrames[#containerFrames + 1] = f end
    end
end

local addonButtons = setmetatable({}, { __mode = "k" }) -- [button] = true
local otherBags = false -- a bag addon has made item buttons
local QueueRebuild      -- (Highlights)

local blizzardBagFrames = {}
if ContainerFrameCombinedBags then blizzardBagFrames[ContainerFrameCombinedBags] = true end
for i = 1, (NUM_CONTAINER_FRAMES or 13) do
    local f = _G["ContainerFrame" .. i]
    if f then blizzardBagFrames[f] = true end
end

-- A template button made outside Blizzard's windows is a bag addon's.
local function OnBagButtonCreated(button)
    if blizzardBagFrames[button:GetParent()] then return end
    addonButtons[button] = true
    otherBags = true
    if ns.db then QueueRebuild() end -- drawn on once the addon has set it up
end

if ContainerFrameItemButtonMixin and ContainerFrameItemButtonMixin.OnLoad then
    hooksecurefunc(ContainerFrameItemButtonMixin, "OnLoad", OnBagButtonCreated)
end

-- Opening the bags (key bindings, the bag bar, vendors) shows a bag addon's window.
local function OnBagsToggled()
    if otherBags and ns.db then QueueRebuild() end
end
for _, name in ipairs({ "OpenAllBags", "ToggleAllBags", "OpenBackpack", "ToggleBackpack", "OpenBag", "ToggleBag" }) do
    if _G[name] then hooksecurefunc(name, OnBagsToggled) end
end

-- The bag and slot a bag addon's button shows, if it's your bags' and shows that
-- item (bag addons also use the buttons for other characters and guild banks).
local function AddonButtonSlot(button)
    local slot, bag = button:GetID(), button:GetBagID()
    if not slot or slot < 1 or not bag or bag < 0 or bag > LAST_ANY_BAG then return end
    local icon = button.icon
    local shown = type(icon) == "table" and icon.GetTexture and icon:GetTexture()
    if type(shown) == "number" then
        local info = GetContainerItemInfo(bag, slot)
        if not info or info.iconFileID ~= shown then return end
    end
    return bag, slot
end

-- fn(button, bag, slot) for each bag addon button on screen with one of your slots.
local function ForEachAddonButton(fn)
    for button in pairs(addonButtons) do
        if button:IsVisible() then
            local bag, slot = AddonButtonSlot(button)
            if bag then fn(button, bag, slot) end
        end
    end
end

local function AddonBagsOpen()
    for button in pairs(addonButtons) do
        if button:IsVisible() then return true end
    end
    return false
end

local function BagsOpen()
    for _, frame in ipairs(containerFrames) do
        if frame:IsShown() then return true end
    end
    return otherBags and AddonBagsOpen()
end

-- A bag addon in use: one made bag buttons, or no Blizzard bag window is open.
local function OtherBagsInUse()
    if otherBags then return true end
    for _, frame in ipairs(containerFrames) do
        if frame:IsVisible() then return false end
    end
    return true
end

-- fn(button, bag, slot) for each item button in Blizzard's open bag windows.
local function ForEachBagButton(fn)
    for _, frame in ipairs(containerFrames) do
        if frame:IsShown() then
            if frame.EnumerateValidItems then
                for _, button in frame:EnumerateValidItems() do
                    fn(button, button:GetBagID(), button:GetID())
                end
            else
                local name, bag = frame:GetName(), frame:GetID()
                for j = 1, 40 do
                    local button = _G[name .. "Item" .. j]
                    if not button then break end
                    if button:IsShown() then fn(button, bag, button:GetID()) end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Stars and quest marks
---------------------------------------------------------------------------

local stars = {}       -- [bag button] = star texture
local anyKept = false

local function SetKeep(itemID, keep)
    ns.db.keep[itemID] = keep or nil
    ns.OnOptionsChanged()
end

-- With a click sound, and the tooltip drawn again for its line.
local function ToggleKeep(itemID)
    local keep = not ns.db.keep[itemID]
    SetKeep(itemID, keep)
    if PlaySound and SOUNDKIT then
        PlaySound(keep and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
    if GameTooltip:IsShown() and GameTooltip.RefreshData then GameTooltip:RefreshData() end
end

-- The click that stars a bag item. A modified click never uses or picks up an
-- item in the default bags.
local hookedBagButtons = {}

-- The click chosen in the settings, never with Shift.
local function IsKeepClick(mouseButton)
    local click = KEEP_CLICKS[ns.db.keepClick]
    if not click or mouseButton ~= click.button or IsShiftKeyDown() then return false end
    return (click.ctrl or false) == IsControlKeyDown() and (click.alt or false) == IsAltKeyDown()
end

local function OnBagItemClick(button, mouseButton)
    if not ns.db or not IsKeepClick(mouseButton) then return end
    local bag, slot
    if addonButtons[button] then
        bag, slot = AddonButtonSlot(button)
        if not bag then return end
    else
        bag, slot = button.GetBagID and button:GetBagID() or button:GetParent():GetID(), button:GetID()
    end
    local info = GetContainerItemInfo(bag, slot)
    if info and info.itemID then ToggleKeep(info.itemID) end
end

local function HookBagButton(button)
    if hookedBagButtons[button] then return end
    hookedBagButtons[button] = true
    button:HookScript("OnClick", OnBagItemClick)
end

local function ShowStar(button)
    local star = stars[button]
    if not star then
        star = button:CreateTexture(nil, "OVERLAY", nil, 7)
        star:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
        star:SetSize(14, 14)
        star:SetPoint("TOPRIGHT", -2, -2)
        stars[button] = star
    end
    star:Show()
end

-- Mark quest items: Blizzard's quest "!" where a highlight's number would go (a
-- kept item is never highlighted), not on the game's own quest items.
local questMarks = {}  -- [bag button] = texture

local function UpdateQuestMark(button, bag, slot, itemID)
    local quest = GetContainerItemQuestInfo(bag, slot)
    if quest and (quest.isQuestItem or quest.questID) then return end
    local name, _, _, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(itemID)
    if not name then
        WaitForItemInfo(itemID)
        return
    end
    if bindType == 4 or not NeededForQuest(itemID, name) then return end
    local mark = questMarks[button]
    if not mark then
        mark = button:CreateTexture(nil, "OVERLAY", nil, 7)
        mark:SetAtlas("QuestNormal")
        mark:SetSize(16, 16)
        mark:SetPoint("TOPLEFT", 1, -1)
        questMarks[button] = mark
    end
    mark:Show()
end

-- One bag button: its highlight, star and quest mark.
local function UpdateBagButton(button, bag, slot)
    -- The bags make buttons as they need them, so each is hooked when it's seen.
    HookBagButton(button)
    if not bag or not slot then return end
    local key = SlotKey(bag, slot)
    local rank = rankBySlot[key]
    if rank then
        local o = GetOverlay(button)
        ApplyGlowStyle(o)
        o.text:SetText(rank)
        o.rank = rank
        o.entry = entryBySlot[key]
        o:Show()
    end
    if anyKept or ns.db.questMark then
        local info = GetContainerItemInfo(bag, slot)
        if info and ns.db.keep[info.itemID] then ShowStar(button) end
        if info and ns.db.questMark then UpdateQuestMark(button, bag, slot, info.itemID) end
    end
end

-- Hides every highlight, star and mark, then draws them on the buttons on screen.
local function RefreshOverlays()
    for _, o in pairs(overlays) do
        o:Hide()
        o.entry = nil
    end
    for _, star in pairs(stars) do star:Hide() end
    for _, mark in pairs(questMarks) do mark:Hide() end
    anyKept = next(ns.db.keep) ~= nil
    ForEachBagButton(UpdateBagButton)
    if otherBags then ForEachAddonButton(UpdateBagButton) end
end

---------------------------------------------------------------------------
-- Highlights
---------------------------------------------------------------------------
-- Which slots are highlighted: the Test button's preview, the loot pairs while
-- looting with full bags, or the cheapest items (Show highlights).

-- Whether a pair's bag item is still where it was paired. (Retail: the same
-- item at another item level has its own link.)
local function PairValid(pair)
    if not pair.bag then return false end
    local info = GetContainerItemInfo(pair.bag, pair.slot)
    return info ~= nil and info.itemID == pair.itemID and (not IS_RETAIL or info.hyperlink == pair.link)
end

local PREVIEW_SECONDS = 15
local previewUntil = 0

-- The cheapest items, as many as Items to highlight; returns how many.
local function HighlightCheapest()
    local n = 0
    for rank = 1, min(ns.db.count, #candidates) do
        local e = candidates[rank]
        local key = SlotKey(e.bag, e.slot)
        rankBySlot[key] = rank
        entryBySlot[key] = e
        n = rank
    end
    return n
end

-- The cheapest items, or with nothing deletable the first items in the bags.
local function ApplyPreview()
    local n = HighlightCheapest()
    if n > 0 then return end
    for _, bag in ipairs(NormalBags()) do
        for slot = 1, GetContainerNumSlots(bag) do
            if n >= ns.db.count then return end
            if GetContainerItemInfo(bag, slot) then
                n = n + 1
                rankBySlot[SlotKey(bag, slot)] = n
            end
        end
    end
end

local function ApplyHighlights()
    wipe(rankBySlot)
    wipe(entryBySlot)
    local mode = ns.db.highlightMode
    if not loot.session and GetTime() < previewUntil then
        ApplyPreview()
    elseif mode ~= SHOW_OFF then
        if loot.session then
            for _, pair in pairs(lootPairs) do
                if PairValid(pair) then
                    local key = SlotKey(pair.bag, pair.slot)
                    rankBySlot[key] = pair.rank
                    entryBySlot[key] = pair
                end
            end
        elseif mode == SHOW_ALWAYS or (mode == SHOW_NEARLY_FULL and FreeSlots() <= NEARLY_FULL_SLOTS) then
            HighlightCheapest()
        end
    end
    RefreshOverlays()
end

local function Rebuild()
    ScanBags()
    ApplyHighlights()
end

-- Many bag events can come in one frame: one rebuild, on the next frame.
local rebuildQueued = false
local function RunQueuedRebuild()
    rebuildQueued = false
    Rebuild()
end

QueueRebuild = function()
    if rebuildQueued then return end
    rebuildQueued = true
    After(0, RunQueuedRebuild)
end

-- Blizzard's bag windows: the highlights again when one opens or updates.
local function HookContainerFrames()
    for _, frame in ipairs(containerFrames) do
        frame:HookScript("OnShow", QueueRebuild)
        if frame.UpdateItems then
            hooksecurefunc(frame, "UpdateItems", QueueRebuild)
        end
    end
end

local function EndPreview()
    if GetTime() >= previewUntil then ApplyHighlights() end
end

-- The Test button. It doesn't open the bags: from addon code with WoW
-- Forever's gamepad UI on, that gets SetPreferredGamepadInteractTarget blocked.
local function StartPreview()
    if not ns.db then return end
    previewUntil = GetTime() + PREVIEW_SECONDS
    Rebuild()
    After(PREVIEW_SECONDS, EndPreview)
end

ns.overlays, ns.hookedBagButtons, ns.rankBySlot, ns.entryBySlot = overlays, hookedBagButtons, rankBySlot, entryBySlot
ns.GOLD_R, ns.GOLD_G, ns.GOLD_B, ns.PREVIEW_SECONDS = GOLD_R, GOLD_G, GOLD_B, PREVIEW_SECONDS
ns.CollectContainerFrames, ns.HookContainerFrames, ns.ForEachBagButton = CollectContainerFrames, HookContainerFrames, ForEachBagButton
ns.BagsOpen, ns.OtherBagsInUse, ns.PairValid, ns.SetKeep = BagsOpen, OtherBagsInUse, PairValid, SetKeep
ns.StartPreview, ns.ApplyHighlights, ns.Rebuild, ns.QueueRebuild = StartPreview, ApplyHighlights, Rebuild, QueueRebuild
