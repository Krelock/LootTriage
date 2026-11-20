-- LootTriage's settings: the list of them, its page under Options > AddOns (a
-- button that opens LootTriage's own window, or with the gamepad UI Blizzard's
-- rows on pages), and /lt.
--
-- Sections: The settings, Options page, Slash commands.
local ADDON_NAME, ns = ...

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local ipairs, pairs, next = ipairs, pairs, next
local min = math.min

local IS_RETAIL, defaults, KEEP_CLICKS, KEEP_CLICK_OFF = ns.IS_RETAIL, ns.defaults, ns.KEEP_CLICKS, ns.KEEP_CLICK_OFF
local SHOW_OFF, SHOW_LOOTING, SHOW_NEARLY_FULL, SHOW_ALWAYS = ns.SHOW_OFF, ns.SHOW_LOOTING, ns.SHOW_NEARLY_FULL, ns.SHOW_ALWAYS
local SORT_OFF, SORT_BOTTOM_RIGHT, SORT_TOP_LEFT = ns.SORT_OFF, ns.SORT_BOTTOM_RIGHT, ns.SORT_TOP_LEFT
local MARK_OFF, MARK_QUESTS, MARK_ALL = ns.MARK_OFF, ns.MARK_QUESTS, ns.MARK_ALL
local candidates, Print, ValueText, ItemIDFromLink = ns.candidates, ns.Print, ns.ValueText, ns.ItemIDFromLink
local PREVIEW_SECONDS, StartPreview, Rebuild, SetKeep = ns.PREVIEW_SECONDS, ns.StartPreview, ns.Rebuild, ns.SetKeep
local OnOptionsChanged, ShowWhatsNew = ns.OnOptionsChanged, ns.ShowWhatsNew

---------------------------------------------------------------------------
-- The settings
---------------------------------------------------------------------------
-- Page by page, in order: { page = name } starts a page, { header = text } a
-- section, { column = 2 } the window's right column. A row has kind, key,
-- name and tip; a slider min, max and format(value) for the text beside it; a
-- dropdown choices(), its { value, name } pairs; a button text and onClick.
-- forever: not on Retail. needsPrice: grayed out without a price addon.

-- Dropdown choices: names[first] to names[last].
local function Choices(names, first, last)
    return function()
        local list = {}
        for value = first, last do list[#list + 1] = { value, names[value] } end
        return list
    end
end

local QUALITY_NAMES = { [0] = "Grays only", [1] = "Grays + whites", [2] = "Grays + whites + greens" }
local SORT_NAMES = { [SORT_OFF] = "Off", [SORT_BOTTOM_RIGHT] = "Bottom right", [SORT_TOP_LEFT] = "Top left" }
local MARK_NAMES = { [MARK_OFF] = "Off", [MARK_QUESTS] = "Quest items", [MARK_ALL] = "Every kept item" }
local SHOW_NAMES = {
    [SHOW_OFF] = "Off",
    [SHOW_LOOTING] = "While looting with full bags",
    [SHOW_NEARLY_FULL] = "When bags are nearly full (4 free slots or fewer)",
    [SHOW_ALWAYS] = "Always",
}

local function KeepClickChoices()
    local list = { { KEEP_CLICK_OFF, "Off" } }
    for i, click in ipairs(KEEP_CLICKS) do list[#list + 1] = { i, click.name } end
    return list
end

-- Only the price addons installed; "None" without one.
local function PriceSourceChoices()
    local list = {}
    for _, source in ipairs(ns.priceSources) do list[#list + 1] = { source.key, source.name } end
    if not ns.priceAddon then list[#list + 1] = { "", "None" } end
    return list
end

local GONE_FOR_GOOD = "\n\n" .. RED_FONT_COLOR:WrapTextInColorCode("Deleting can't be undone: the item can't be bought back from a vendor.")
local NEEDS_PRICE_ADDON = "Needs Auctionator, TradeSkillMaster, AuctionMaster or Blackthornes Tradeskills. Install one to use this."

local SETTINGS = {
    { header = "Highlights" },
    { kind = "dropdown", key = "highlightMode", name = "Show highlights", choices = Choices(SHOW_NAMES, SHOW_OFF, SHOW_ALWAYS),
        tip = "When to highlight items in your bags. While looting with full bags, your bags show what to delete for each loot item. Loot coins and sorting work in every mode." },
    { kind = "slider", key = "count", name = "Items to highlight", min = 1, max = 20,
        tip = "How many of your cheapest items get highlighted when not looting. Only used with \"When bags are nearly full\" and \"Always\"." },
    { kind = "button", name = "Preview highlights", text = "Test", onClick = StartPreview,
        tip = function()
            return ("Shows the highlights on your cheapest items for %d seconds. Open your bags to see how they look."):format(PREVIEW_SECONDS)
        end },
    { kind = "dropdown", key = "maxQuality", name = "Item qualities", choices = Choices(QUALITY_NAMES, 0, 2),
        tip = "The highest item quality that can be suggested for deletion." },
    { column = 2 },
    { header = "Loot window" },
    { kind = "checkbox", key = "lootAdvice", name = "Loot coins when bags are full",
        tip = "When your bags are full, put a gold coin on loot that's worth more than the bag item it would replace." },
    { kind = "checkbox", key = "trashButton", name = "Delete button",
        tip = "While your bags are full, the loot window gets a small red delete button. Each click deletes the cheapest item in your bags that better loot can replace. Hover it to see which item."
            .. "\n\nNever in combat."
            .. GONE_FOR_GOOD },
    { kind = "checkbox", key = "doubleClickLoot", name = "Double-click loot to make room",
        tip = "While your bags are full, double-click loot with a gold coin to delete the cheapest item in your bags and loot it. Hover the loot to see which item."
            .. "\n\nOnly in Blizzard's loot window. Never in combat."
            .. GONE_FOR_GOOD },
    { header = "Bags" },
    { kind = "dropdown", key = "keepClick", name = "Click in bags", choices = KeepClickChoices,
        tip = "Click an item in your bags this way and it's never suggested for deletion (it gets a gold border). Click again to undo." },
    { kind = "dropdown", key = "markItems", name = "Mark items", choices = Choices(MARK_NAMES, MARK_OFF, MARK_ALL),
        tip = "A small icon on items LootTriage keeps: the quest ! on quest items, or an icon for every kind it keeps." },
    { kind = "checkbox", key = "tooltipLines", name = "Tooltip lines",
        tip = "LootTriage's lines in item tooltips, like the delete number and why an item is kept." },

    { page = "Never highlight" },
    { header = "Consumables" },
    { kind = "checkbox", key = "keepPotions", name = "Potions and elixirs",
        tip = "Potions, elixirs and flasks." },
    { kind = "checkbox", key = "keepFood", name = "Food and drink",
        tip = "Food and drink, buff food too." },
    { kind = "checkbox", key = "keepBandages", name = "Bandages",
        tip = "Linen Bandage and the other first aid bandages." },
    { kind = "checkbox", key = "keepScrolls", name = "Scrolls",
        tip = "Scroll of Stamina, Scroll of Intellect and the other scrolls." },
    { kind = "checkbox", key = "keepConsumables", name = "Other consumables",
        tip = "Every other consumable: sharpening stones, weightstones, oils, explosives and the like." },
    { header = "Gear" },
    { kind = "checkbox", key = "keepUsableGear", name = "Gear you can use",
        tip = "Weapons and armor your class can wear or wield, whatever their level." },
    { kind = "checkbox", key = "keepBoEGear", name = "Bind-on-equip gear",
        tip = "Weapons and armor that bind when equipped and aren't bound to you yet, for the auction house or a friend." },
    { column = 2 },
    { header = "Crafting" },
    { kind = "checkbox", key = "keepReagents", name = "Crafting reagents",
        tip = "Cloth, herbs, ore, leather and other crafting materials." },
    { kind = "checkbox", key = "reagentsMyProfessions", name = "Only for your professions", forever = true,
        tip = "With Crafting reagents on, only keep materials your professions use, like cloth for tailoring or herbs for alchemy." },
    { kind = "checkbox", key = "keepSpellReagents", name = "Spell reagents",
        tip = "Rune of Teleportation, Light Feather, Flash Powder, Symbol of Divinity and other items spells use up." },
    { kind = "checkbox", key = "keepTools", name = "Profession tools",
        tip = "Mining Pick, Blacksmith Hammer, Skinning Knife, fishing poles, enchanting rods, Flint and Tinder, etc." },
    { kind = "checkbox", key = "keepRecipes", name = "Recipes",
        tip = "Recipes, patterns, plans, formulas and schematics." },
    { header = "Bags and ammo" },
    { kind = "checkbox", key = "keepBags", name = "Bags and quivers",
        tip = "Bags, profession bags, quivers and ammo pouches." },
    { kind = "checkbox", key = "keepAmmo", name = "Arrows and bullets",
        tip = "Arrows and bullets for your ranged weapon." },

    -- The list of quests not picked up yet is only used on WoW Forever.
    { page = "Quests" },
    { header = "Kept" },
    { kind = "checkbox", key = "keepQuestItems", name = "Items for quests in your log",
        tip = "Items the quests in your quest log ask you to bring." },
    { kind = "checkbox", key = "keepUnstartedQuestItems", name = "Items for quests not picked up yet", forever = true,
        tip = "Items quests you haven't done yet will ask for, for your race and class. Kept until you've done those quests." },
    { kind = "slider", key = "questLevelsAbove", name = "Quest levels above yours", min = 0, max = 60, forever = true,
        tip = "Items for quests not picked up yet are only kept when you can pick up the quest within this many levels of yours. 60 keeps them for every quest." },
    { kind = "checkbox", key = "skipGrayQuests", name = "Skip low-level quests", forever = true,
        tip = "Items for quests not picked up yet aren't kept once the quest is gray for you (too low to give experience)." },
    { kind = "checkbox", key = "keepRepeatableQuestItems", name = "Items for repeatable quests",
        tip = "Items for quests you can do again and again, like reputation and Darkmoon Faire turn-ins." },
    { column = 2 },
    { header = "Other" },
    { kind = "checkbox", key = "leftoverQuestItems", name = "Leftover quest items",
        tip = "Quest items you don't need anymore, because you've done their quests, can be suggested for deletion. They're usually ones a vendor won't buy." },

    { page = "Sorting" },
    { kind = "dropdown", key = "sortCorner", name = "Junk after sorting", choices = Choices(SORT_NAMES, SORT_OFF, SORT_TOP_LEFT),
        tip = "After you hit sort, your junk gets moved to the bottom right, cheapest in the last slot. Top left puts it in the top left instead, cheapest in the first slot." },
    { kind = "checkbox", key = "closeGaps", name = "Close gaps after sorting",
        tip = "After your junk is moved, your other items move up so no empty slots are left between them." },

    { page = "Auction prices" },
    { kind = "checkbox", key = "auctionPrices", name = "Auction prices", needsPrice = true,
        tip = "Count an item as worth its auction price when that's more than a vendor pays. Gray items, soulbound items and prices older than Price age use the vendor price." },
    { kind = "dropdown", key = "priceSource", name = "Price source", choices = PriceSourceChoices, needsPrice = true,
        tip = "Which addon's auction prices to use. TradeSkillMaster's are its market value from the TSM desktop app and have no age, so Price age doesn't apply to them." },
    { kind = "slider", key = "auctionMaxAge", name = "Price age", min = 1, max = 30, needsPrice = true,
        tip = "Auction prices older than this many days use the vendor price instead." },
    { kind = "slider", key = "auctionCutPercent", name = "Auction house cut", min = 0, max = 15, needsPrice = true,
        tip = "How much of each auction price the auction house keeps.",
        format = function(value) return ("%d%%"):format(value) end },
}

-- A row's tooltip (tip, or what tip() gives); without a price addon, a red line
-- says what it needs.
local function RowTip(row)
    local tip = type(row.tip) == "function" and row.tip() or row.tip
    if row.needsPrice and not ns.priceAddon then
        return tip .. "\n\n" .. RED_FONT_COLOR:WrapTextInColorCode(NEEDS_PRICE_ADDON)
    end
    return tip
end

-- A setting changed in the window or Blizzard's rows.
local function SetOption(key, value)
    ns.db[key] = value
    OnOptionsChanged()
end

---------------------------------------------------------------------------
-- Options page
---------------------------------------------------------------------------

local settingsCategory

-- Blizzard's own check (InputUtil.IsGamepadUIEnabled); Retail may have neither.
local function GamepadUI()
    local style = C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle and C_InputInterfaceStyle.GetCurrentStyle()
    return Enum.InputDeviceInterfaceType ~= nil and style == Enum.InputDeviceInterfaceType.Gamepad
end

-- The window can't be reached with a controller, and one that errored on opening in
-- this version isn't tried again until the next version: then the settings are
-- Blizzard's rows. Blizzard's dropdowns are built from LootTriage's choices, so their
-- menus run as LootTriage's: the window is used where it can be.
local function OptionsOnly()
    if GamepadUI() then return true end
    local version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
    if ns.db.settingsWindowFailed ~= version then ns.db.settingsWindowFailed = false end
    return ns.db.settingsWindowFailed ~= false
end

-- Every setting as Blizzard's rows, a page each under LootTriage's.
local function AddRows(main, layout, pages)
    local category = main

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

    local CreateDropdown = Settings.CreateDropdown or Settings.CreateDropDown
    for _, row in ipairs(SETTINGS) do
        local initializer
        if row.page then
            Page(row.page)
        elseif row.header then
            Header(row.header)
        elseif row.kind and not (row.forever and IS_RETAIL) then
            local tip = RowTip(row)
            if row.kind == "checkbox" then
                initializer = Settings.CreateCheckbox(category, Setting(row.key, row.name), tip)
            elseif row.kind == "slider" then
                local options = Settings.CreateSliderOptions(row.min, row.max, 1)
                if MinimalSliderWithSteppersMixin then
                    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, row.format)
                end
                initializer = Settings.CreateSlider(category, Setting(row.key, row.name), options, tip)
            elseif row.kind == "dropdown" then
                local choices = row.choices
                local function Options()
                    local container = Settings.CreateControlTextContainer()
                    for _, choice in ipairs(choices()) do container:Add(choice[1], choice[2]) end
                    return container:GetData()
                end
                initializer = CreateDropdown(category, Setting(row.key, row.name), Options, tip)
            elseif row.kind == "button" and CreateSettingsButtonInitializer then
                -- No search tags (false): from addon code they'd be tainted, and the settings
                -- search reads every row's, so Blizzard's actions in its results get blocked.
                layout:AddInitializer(CreateSettingsButtonInitializer(row.name, row.text, row.onClick, tip, false))
            end
            -- Grayed out without a price addon. Only the row reads its modify
            -- predicates (not the search), so they can't taint it.
            if initializer and row.needsPrice and not ns.priceAddon then
                initializer:AddModifyPredicate(function() return false end)
            end
        end
    end
end

local function RegisterSettings()
    local main, layout = Settings.RegisterVerticalLayoutCategory("LootTriage")
    local pages = { [main] = true }
    if ns.ShowSettingsWindow and not OptionsOnly() then
        if CreateSettingsButtonInitializer then
            layout:AddInitializer(CreateSettingsButtonInitializer("LootTriage settings", "Open", ns.ShowSettingsWindow,
                "All of LootTriage's settings, in its own window. /lt opens it too.", false))
        end
    else
        AddRows(main, layout, pages)
    end
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

-- /lt: the window, or Blizzard's options where the window isn't used.
local function OpenSettings()
    if ns.ShowSettingsWindow and not OptionsOnly() then
        ns.ShowSettingsWindow()
    elseif settingsCategory then
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
    print("  /lt keeplist - list kept items")
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
            Print("no kept items.")
            return
        end
        Print("kept items (never suggested for deletion):")
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
ns.SETTINGS, ns.RowTip, ns.SetOption = SETTINGS, RowTip, SetOption
