-- LootTriage's What's New dialog: the patch notes, opened by the What's New
-- button on the settings pages, in the look of Blizzard's dialogs.
local ADDON_NAME, ns = ...

local ipairs = ipairs

-- Newest version first; one without a version uses the .toc's. An item is
-- { name (in gold), what it does }, or a line.
local WHATS_NEW = {
    { version = "1.1.5",
        { "Changes", {
            "While you loot with full bags, the bag items worth deleting for your loot now sparkle with the animated proc glow. Other highlights keep the still gold border, so you can see which swaps are worth making without guessing.",
            "The Animated glow setting is gone.",
        } },
    },
    { version = "1.1.0",
        { "New", {
            { "Settings pages (nothing to set).", "The settings are split into pages: LootTriage, Never highlight, Quests, Sorting and Auctionator. Click the plus next to LootTriage in the list to see them." },
            { "Items for quests not picked up yet (on if you had Items for quests on).", "Items for quests is two settings now: quests in your log, and quests you haven't picked up yet. On the Quests page." },
            { "Quest levels above yours (60: every quest).", "Items for quests not picked up yet are only kept when you can pick up the quest within that many levels. On the Quests page." },
            { "Skip low-level quests (off by default).", "Items for quests that are gray for you aren't kept. On the Quests page." },
            { "Price age (14 days).", "How old an auction price can be before the vendor price is used instead. On the Auctionator page." },
            { "Auction house cut (0%: off).", "Auction prices count that much less, for the part of each sale the auction house keeps. On the Auctionator page." },
            { "Quests in the tooltip (nothing to set).", "Under \"needed for a quest\", the tooltip names the quests that keep the item, with (in your log) or (repeatable) after them." },
            { "Mark quest items (off by default).", "A small quest ! on the items in your bags that LootTriage keeps for a quest. On the Quests page." },
        } },
        { "Changes", {
            "Items for quests is called Items for quests in your log now, and is on the Quests page.",
            "Without Auctionator, its page still shows, grayed out, and its tooltips say you need the Auctionator addon.",
        } },
        { "Fixes", {
            "Items for quests not picked up yet no longer keeps items for the other faction's quests, like the war effort turn-ins (\"The Horde Needs ...!\") and Elixirs for the Bladeleafs.",
            "Close gaps after sorting no longer moves items in a bag set to Ignore this bag (Cleanup).",
        } },
    },
    { version = "1.0.9",
        { "New", {
            { "Auction prices (off by default).", "With Auctionator installed, white items and above go by their auction house price instead of the vendor price when it's higher. Turn it on under Auctionator in the settings." },
            { "What's New button (nothing to set).", "At the top of LootTriage's settings page, next to Defaults. It shows these notes in game, and the right arrow shows the notes of the version before." },
        } },
    },
    { version = "1.0.8",
        { "New", {
            "New Items for quests setting at the top of Never highlight (off by default): items a quest asks you to bring are never suggested for deletion. That covers what the quests in your quest log need, and on WoW Forever also what quests you haven't done yet will ask for (for your race and class), like Goretusk Liver or the Green Hills of Stranglethorn pages. Once you've done a quest, its items can be suggested again.",
            "New Items for repeatable quests setting (off by default): turn-ins for quests you can do again and again, like reputation and Darkmoon Faire turn-ins, are never suggested for deletion.",
            "Hovering an item a quest needs shows \"LootTriage: needed for a quest, never suggested for deletion\".",
            "The list of quest items comes from the cmangos classic-db project (GPL-3.0).",
            "New Close gaps after sorting setting under Sorting (off by default). After you sort your bags and your junk is moved to the corner, your other items move up too, so no empty slots are left between them. They keep the order the sort gave them, and the free slots end up together next to the junk. Sorting takes a little longer with it on. With it off, sorting works just like before.",
        } },
    },
}
-- No parent in CreateFrame (see GetOverlay in Bags.lua).
local function NewFrame(kind, parent)
    local frame = CreateFrame(kind)
    frame:SetParent(parent)
    return frame
end
local function DialogButton(parent, text, onClick)
    local button = NewFrame("Button", parent)
    button:SetSize(128, 21) -- StaticPopupButtonTemplate's size
    button:SetNormalTexture("Interface\\Buttons\\UI-DialogBox-Button-Up")
    button:GetNormalTexture():SetTexCoord(0, 1, 0, 0.71875)
    button:SetPushedTexture("Interface\\Buttons\\UI-DialogBox-Button-Down")
    button:GetPushedTexture():SetTexCoord(0, 1, 0, 0.71875)
    button:SetHighlightTexture("Interface\\Buttons\\UI-DialogBox-Button-Highlight", "ADD")
    button:GetHighlightTexture():SetTexCoord(0, 1, 0, 0.71875)
    button:SetNormalFontObject(GameFontNormal)
    button:SetHighlightFontObject(GameFontHighlight)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end
local dialog = { page = 1 } -- the dialog's frames and current page
-- Shows a version's notes, sizing the dialog to fit (wider when it's too tall
-- for the screen, so Okay can always be reached).
function dialog.ShowPage()
    local notes = WHATS_NEW[dialog.page]
    local lines = { NORMAL_FONT_COLOR:WrapTextInColorCode(("LootTriage %s"):format(
        notes.version or C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))) }
    for _, section in ipairs(notes) do
        lines[#lines + 1] = "\n" .. NORMAL_FONT_COLOR:WrapTextInColorCode(section[1])
        for _, item in ipairs(section[2]) do
            if type(item) == "table" then item = NORMAL_FONT_COLOR:WrapTextInColorCode(item[1]) .. " " .. item[2] end
            lines[#lines + 1] = "- " .. item
        end
    end
    local frame, text = dialog.frame, dialog.text
    frame:SetWidth(480)
    text:SetWidth(440)
    text:SetText(table.concat(lines, "\n"))
    if text:GetStringHeight() + 73 > UIParent:GetHeight() - 145 then -- the dialog's top is 135 below the screen's
        frame:SetWidth(720)
        text:SetWidth(680)
    end
    frame:SetHeight(text:GetStringHeight() + 73)
    dialog.older:SetEnabled(dialog.page < #WHATS_NEW)
    dialog.newer:SetEnabled(dialog.page > 1)
end
-- Page arrows: 1 = older, -1 = newer.
function dialog.Turn(by)
    if not WHATS_NEW[dialog.page + by] then return end
    dialog.page = dialog.page + by
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    dialog.ShowPage()
end
local function ShowWhatsNew()
    if not dialog.frame then
        local frame = NewFrame("Frame", UIParent)
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        frame:EnableMouse(true)
        frame:SetPoint("TOP", UIParent, "TOP", 0, -135)
        local background = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        background:SetAtlas("UI-DialogBox-Background-Dark", true)
        background:SetPoint("TOPLEFT", 7, -7)
        background:SetPoint("BOTTOMRIGHT", -7, 7)
        local edge = frame:CreateTexture(nil, "BACKGROUND", nil, -4)
        edge:SetAtlas("UI-DiamondDialogBox-Border", true)
        edge:SetAllPoints()
        local text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("TOP", 0, -20)
        text:SetJustifyH("LEFT")
        text:SetSpacing(3)
        text:SetIndentedWordWrap(true) -- indent wrapped lines
        -- Blizzard's page arrows, top right: right = older, left = newer.
        local function ArrowButton(way, by)
            local button = NewFrame("Button", frame)
            button:SetSize(32, 32)
            button:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. way .. "Page-Up")
            button:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. way .. "Page-Down")
            button:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. way .. "Page-Disabled")
            button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
            button:SetScript("OnClick", function() dialog.Turn(by) end)
            return button
        end
        dialog.frame, dialog.text = frame, text
        dialog.older = ArrowButton("Next", 1)
        dialog.older:SetPoint("TOPRIGHT", -14, -10)
        dialog.newer = ArrowButton("Prev", -1)
        dialog.newer:SetPoint("RIGHT", dialog.older, "LEFT", 0, 0)
        DialogButton(frame, OKAY, function() frame:Hide() end):SetPoint("BOTTOM", 0, 16)
    end
    dialog.page = 1 -- open on the newest
    dialog.ShowPage()
    dialog.frame:Show()
end

ns.ShowWhatsNew = ShowWhatsNew
