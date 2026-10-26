-- LootTriage's settings: its page under Options > AddOns, with the Never
-- highlight, Quests, Sorting and Auctionator pages under it, and /lt.
--
-- Sections: Settings pages, Slash commands.
local _, ns = ...

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local ipairs, pairs, next = ipairs, pairs, next
local min = math.min

local IS_RETAIL, defaults, KEEP_CLICKS, KEEP_CLICK_OFF = ns.IS_RETAIL, ns.defaults, ns.KEEP_CLICKS, ns.KEEP_CLICK_OFF
local SHOW_OFF, SHOW_LOOTING, SHOW_NEARLY_FULL, SHOW_ALWAYS = ns.SHOW_OFF, ns.SHOW_LOOTING, ns.SHOW_NEARLY_FULL, ns.SHOW_ALWAYS
local SORT_OFF, SORT_BOTTOM_RIGHT, SORT_TOP_LEFT = ns.SORT_OFF, ns.SORT_BOTTOM_RIGHT, ns.SORT_TOP_LEFT
local candidates, Print, ValueText, ItemIDFromLink = ns.candidates, ns.Print, ns.ValueText, ns.ItemIDFromLink
local PREVIEW_SECONDS, StartPreview, Rebuild, SetKeep = ns.PREVIEW_SECONDS, ns.StartPreview, ns.Rebuild, ns.SetKeep
local OnOptionsChanged, ShowWhatsNew = ns.OnOptionsChanged, ns.ShowWhatsNew

-- Dropdown choices.
local QUALITY_NAMES = { [0] = "Grays only", [1] = "Grays + whites", [2] = "Grays + whites + greens" }
local SORT_NAMES = { [SORT_OFF] = "Off", [SORT_BOTTOM_RIGHT] = "Bottom right", [SORT_TOP_LEFT] = "Top left" }
local SHOW_NAMES = {
    [SHOW_OFF] = "Off",
    [SHOW_LOOTING] = "While looting with full bags",
    [SHOW_NEARLY_FULL] = "When bags are nearly full (4 free slots or fewer)",
    [SHOW_ALWAYS] = "Always",
}

local settingsCategory

---------------------------------------------------------------------------
-- Settings pages
---------------------------------------------------------------------------

local function RegisterSettings()
    -- Rows go to the current page; Page() starts the next one under LootTriage.
    local main, layout = Settings.RegisterVerticalLayoutCategory("LootTriage")
    local category, pages = main, { [main] = true }

    local function Header(text)
        if CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
        end
    end

    -- A game without sub-pages gets a header on the one page instead.
    local function Page(name)
        if Settings.RegisterVerticalLayoutSubcategory then
            category, layout = Settings.RegisterVerticalLayoutSubcategory(main, name)
            pages[category] = true
        else
            Header(name)
        end
    end

    -- A setting saved in LootTriageDB[key].
    local function Setting(key, name)
        local setting = Settings.RegisterAddOnSetting(category, "LootTriage_" .. key, key, ns.db,
            type(defaults[key]), name, defaults[key])
        setting:SetValueChangedCallback(OnOptionsChanged)
        return setting
    end

    local function Checkbox(key, name, tooltip)
        return Settings.CreateCheckbox(category, Setting(key, name), tooltip)
    end

    -- format(value): the text beside the slider (nil: the number).
    local function Slider(key, name, minValue, maxValue, tooltip, format)
        local options = Settings.CreateSliderOptions(minValue, maxValue, 1)
        if MinimalSliderWithSteppersMixin then
            options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, format)
        end
        return Settings.CreateSlider(category, Setting(key, name), options, tooltip)
    end

    -- A dropdown's choices: names[first] to names[last].
    local function Choices(names, first, last)
        return function()
            local container = Settings.CreateControlTextContainer()
            for value = first, last do container:Add(value, names[value]) end
            return container:GetData()
        end
    end

    local CreateDropdown = Settings.CreateDropdown or Settings.CreateDropDown

    CreateDropdown(category, Setting("highlightMode", "Show highlights"), Choices(SHOW_NAMES, SHOW_OFF, SHOW_ALWAYS),
        "When to highlight items in your bags. While looting with full bags, your bags show what to delete for each loot item. Loot coins and sorting work in every mode.")
    Slider("count", "Items to highlight", 1, 20,
        "How many of your cheapest items get highlighted when not looting. Only used with \"When bags are nearly full\" and \"Always\".")
    Checkbox("animatedGlow", "Animated glow",
        "Use the animated ability proc glow (sparkling border) instead of a still gold border.")
    -- No search tags (false): from addon code they'd be tainted, and the settings
    -- search reads every row's, so Blizzard's actions in its results get blocked.
    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer("Preview highlights", "Test", StartPreview,
            ("Shows the highlights on your cheapest items for %d seconds. Open your bags to see how they look."):format(PREVIEW_SECONDS),
            false))
    end
    CreateDropdown(category, Setting("maxQuality", "Item qualities"), Choices(QUALITY_NAMES, 0, 2),
        "The highest item quality that can be suggested for deletion.")
    Checkbox("lootAdvice", "Loot coins when bags are full",
        "When your bags are full, put a gold coin on loot that's worth more than the bag item it would replace.")
    local function KeepClickOptions()
        local container = Settings.CreateControlTextContainer()
        container:Add(KEEP_CLICK_OFF, "Off")
        for i, click in ipairs(KEEP_CLICKS) do container:Add(i, click.name) end
        return container:GetData()
    end
    CreateDropdown(category, Setting("keepClick", "Click in bags"), KeepClickOptions,
        "Click an item in your bags this way to give it a star: it will never be suggested for deletion. Click again to undo. Note: in the default game, Ctrl+click also previews gear in the dressing room.")

    Page("Never highlight")
    Checkbox("keepConsumables", "Consumables",
        "Potions, elixirs, flasks, food, drink, bandages and scrolls.")
    Checkbox("keepReagents", "Crafting reagents",
        "Cloth, herbs, ore, leather and other crafting materials.")
    Checkbox("keepSpellReagents", "Spell reagents",
        "Rune of Teleportation, Light Feather, Flash Powder, Symbol of Divinity and other items spells use up.")
    Checkbox("keepTools", "Profession tools",
        "Mining Pick, Blacksmith Hammer, Skinning Knife, fishing poles, enchanting rods, Flint and Tinder, etc.")
    Checkbox("keepRecipes", "Recipes",
        "Recipes, patterns, plans, formulas and schematics.")
    Checkbox("keepEquipment", "Weapons and armor",
        "Gear you might want to wear, sell or disenchant.")

    -- The list of quests not picked up yet is only used on WoW Forever.
    Page("Quests")
    Checkbox("keepQuestItems", "Items for quests in your log",
        "Items the quests in your quest log ask you to bring.")
    if not IS_RETAIL then
        Checkbox("keepUnstartedQuestItems", "Items for quests not picked up yet",
            "Items quests you haven't done yet will ask for, for your race and class. Kept until you've done those quests.")
        Slider("questLevelsAbove", "Quest levels above yours", 0, 60,
            "Items for quests not picked up yet are only kept when you can pick up the quest within this many levels of yours. 60 keeps them for every quest.")
        Checkbox("skipGrayQuests", "Skip low-level quests",
            "Items for quests not picked up yet aren't kept once the quest is gray for you (too low to give experience).")
    end
    Checkbox("keepRepeatableQuestItems", "Items for repeatable quests",
        "Items for quests you can do again and again, like reputation and Darkmoon Faire turn-ins.")
    Checkbox("questMark", "Mark quest items",
        "Puts a small quest ! on items in your bags that the settings above keep for a quest.")

    Page("Sorting")
    CreateDropdown(category, Setting("sortCorner", "Junk after sorting"), Choices(SORT_NAMES, SORT_OFF, SORT_TOP_LEFT),
        "After you hit sort, your junk gets moved to the bottom right, cheapest in the last slot. Top left puts it in the top left instead, cheapest in the first slot.")
    Checkbox("closeGaps", "Close gaps after sorting",
        "After your junk is moved, your other items move up too, so no empty slots are left between them. They keep the order the sort gave them. Takes a little longer. Not used when Junk after sorting is Off.")

    -- Without Auctionator the rows are grayed out and their tooltips say why. Only
    -- the row reads its modify predicates (not the search), so they can't taint it.
    Page("Auctionator")
    local needs = not ns.auctionator and "\n\n" .. RED_FONT_COLOR:WrapTextInColorCode("Needs the Auctionator addon. Install it to use this.") or ""
    local function NeedsAuctionator(initializer)
        if not ns.auctionator then initializer:AddModifyPredicate(function() return false end) end
    end
    NeedsAuctionator(Checkbox("auctionPrices", "Auction prices",
        "Count an item as worth its auction price when that's more than a vendor pays. Gray items, soulbound items and prices older than Price age use the vendor price." .. needs))
    NeedsAuctionator(Slider("auctionMaxAge", "Price age", 1, 30,
        "Auction prices older than this many days use the vendor price instead." .. needs))
    NeedsAuctionator(Slider("auctionCutPercent", "Auction house cut", 0, 15,
        "How much of each auction price the auction house keeps." .. needs,
        function(value) return ("%d%%"):format(value) end))

    Settings.RegisterAddOnCategory(main)
    settingsCategory = main

    -- The What's New button, left of Defaults atop LootTriage's pages, with
    -- Blizzard's template, size and wording. As the Defaults button's child it
    -- hides with it during a search. No parent in CreateFrame (see GetOverlay in
    -- Bags.lua), and none at all if Blizzard's header isn't as expected.
    local list = SettingsPanel and SettingsPanel.Container and SettingsPanel.Container.SettingsList
    local defaultsButton = list and list.Header and list.Header.DefaultsButton
    if defaultsButton and EventRegistry then
        local button = CreateFrame("Button", nil, nil, "UIPanelButtonTemplate")
        button:SetParent(defaultsButton)
        button:SetSize(96, 22)
        button:SetPoint("RIGHT", defaultsButton, "LEFT", -2, 0)
        button:SetText(GAMEMENU_NEW_BUTTON)
        button:SetScript("OnClick", ShowWhatsNew)
        button:Hide()
        EventRegistry:RegisterCallback("Settings.CategoryChanged", function(_, shown)
            button:SetShown(pages[shown] == true)
        end, button)
    end
end

local function OpenSettings()
    if settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    else
        Print("the settings panel isn't available. Type /lt help for commands.")
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function ShowHelp()
    Print("commands (/lt or /loottriage):")
    print("  /lt - open the settings")
    print("  /lt list - print the delete priority list")
    print(("  /lt test - show the highlights for %d seconds (open your bags to see them)"):format(PREVIEW_SECONDS))
    print("  /lt keep [item] - never suggest an item for deletion (shift-click it into chat)")
    print("  /lt unkeep [item] - allow an item to be suggested again")
    print("  /lt keeplist - list starred items")
end

-- /lt and its commands (ShowHelp lists them).
local function HandleSlash(msg)
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()

    if cmd == "" or cmd == "config" or cmd == "settings" or cmd == "options" then
        OpenSettings()
    elseif cmd == "test" then
        StartPreview()
    elseif cmd == "list" then
        Rebuild()
        if #candidates == 0 then
            Print("nothing to delete - no items match your settings.")
            return
        end
        Print("delete priority (first = delete first):")
        for i = 1, min(10, #candidates) do
            local e = candidates[i]
            local stack = e.count > 1 and (" x" .. e.count) or ""
            print(("  %d. %s%s - %s"):format(i, e.link or "?", stack, ValueText(e)))
        end
    elseif cmd == "keep" or cmd == "unkeep" then
        local id = ItemIDFromLink(rest) or tonumber(rest)
        if not id then
            Print("usage: /lt " .. cmd .. " [shift-click an item]")
            return
        end
        SetKeep(id, cmd == "keep")
        local link = select(2, GetItemInfo(id)) or ("item " .. id)
        Print(link .. (cmd == "keep" and " will never be suggested for deletion." or " can be suggested for deletion again."))
    elseif cmd == "keeplist" then
        if next(ns.db.keep) == nil then
            Print("no starred items.")
            return
        end
        Print("starred items (never suggested for deletion):")
        for id in pairs(ns.db.keep) do
            print("  " .. (select(2, GetItemInfo(id)) or ("item " .. id)))
        end
    else
        ShowHelp()
    end
end

SLASH_LOOTTRIAGE1 = "/loottriage"
SLASH_LOOTTRIAGE2 = "/lt"
SlashCmdList.LOOTTRIAGE = HandleSlash

ns.RegisterSettings = RegisterSettings
