-- LootTriage's own settings window: its pages in a list on the left (LootTriage,
-- Never highlight, Quests, Sorting, Auction prices), each in two columns, built
-- from the settings list in Settings.lua. Blizzard's options list isn't used for
-- them: its dropdowns are built from the addon's choices, so their menus run as
-- the addon's code.
--
-- Sections: Parts, Pages, The window.

local ADDON_NAME, ns = ...

local ipairs, floor = ipairs, math.floor

local window
local refreshing -- the page is being filled in: its sliders' moves aren't changes

local LIST = 180          -- the list's width
local COLUMN = 150        -- where a row's control starts, after its label
local LEFT, RIGHT, WIDE = 16, 400, 340 -- the columns, and how wide their words go
local BROWN = { 27 / 255, 23 / 255, 18 / 255 } -- the theme's dark brown (#1B1712)

---------------------------------------------------------------------------
-- Parts
---------------------------------------------------------------------------
-- Frames are made with no parent, then SetParent (the gamepad UI hooks CreateFrame).

local function New(kind, parent, template)
    local frame = CreateFrame(kind, nil, nil, template)
    frame:SetParent(parent)
    return frame
end

local function Label(parent, text, font)
    local label = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
    label:SetText(text)
    return label
end

-- The row's name in gold, its tooltip in white (worked out when it shows).
local function Tooltip(frame, row)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(row.name)
        GameTooltip:AddLine(ns.RowTip(row), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Set(key, value) ns.SetOption(key, value) end

-- A frame over a label that shows the row's tooltip (and clicks the box, if given).
local function Hover(parent, label, row, box)
    local hover = New("Frame", parent)
    hover:SetPoint("TOPLEFT", label, "TOPLEFT", 0, 4)
    hover:SetPoint("BOTTOMRIGHT", label, "BOTTOMRIGHT", 4, -4)
    hover:EnableMouse(true)
    if box then hover:SetScript("OnMouseDown", function() box:Click() end) end
    Tooltip(hover, row)
    return hover
end

-- A gold label on the left, the control at COLUMN (a checkbox's label clicks it).
local function Row(control, row, box)
    local label = Label(control, row.name)
    label:SetWidth(COLUMN - 8)
    label:SetJustifyH("LEFT")
    label:SetPoint("LEFT", control, "LEFT", -COLUMN, 0)
    control.hover = Hover(control, label, row, box)
    control.label, control.inRow = label, true
end

-- A checkbox right of its words, as in Blizzard's options.
local function Checkbox(page, row)
    local box = New("CheckButton", page, "MinimalCheckboxTemplate")
    box:SetSize(26, 26)
    box:SetScript("OnClick", function(self)
        PlaySound(self:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        Set(row.key, self:GetChecked() == true)
    end)
    Row(box, row, box)
    Tooltip(box, row)
    return box
end

local function Slider(page, row)
    local slider = New("Frame", page, "MinimalSliderWithSteppersTemplate")
    slider:SetWidth(110)
    local right = MinimalSliderWithSteppersMixin.Label.Right
    slider:Init(row.min, row.min, row.max, row.max - row.min, { [right] = CreateMinimalSliderFormatter(right, row.format) })
    slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        if not refreshing then Set(row.key, floor(value + 0.5)) end
    end, slider)
    Row(slider, row)
    for _, part in ipairs({ slider.Slider, slider.Back, slider.Forward }) do Tooltip(part, row) end
    return slider
end

-- Radio choices, saved as the choice's value. Its two functions are made once:
-- the menu hands them the choice's value (each menu built is garbage later).
local function Dropdown(page, row)
    local dropdown = New("DropdownButton", page, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(168)
    local function IsPicked(value) return ns.db[row.key] == value end
    local function Pick(value) Set(row.key, value) end
    -- Blizzard's template builds the whole menu each time the dropdown shows, and
    -- SetupMenu builds it at once if shown, only to show the chosen option's name:
    -- here it's built when the menu opens, and RefreshPage writes the name.
    dropdown:SetScript("OnShow", nil)
    dropdown:Hide()
    dropdown:SetupMenu(function(_, root)
        for _, choice in ipairs(row.choices()) do root:CreateRadio(choice[2], IsPicked, Pick, choice[1]) end
    end)
    dropdown:Show()
    Row(dropdown, row)
    Tooltip(dropdown, row)
    return dropdown
end

local function Button(page, row)
    local button = New("Button", page, "UIPanelButtonTemplate")
    button:SetSize(96, 22)
    button:SetText(row.text)
    button:SetScript("OnClick", function() row.onClick() end)
    Row(button, row)
    Tooltip(button, row)
    return button
end

-- A section's name with a gold line under it, fading out.
local function Header(page, text)
    local header = New("Frame", page)
    header:SetSize(WIDE, 22)
    header.height, header.gap = 30, 4
    header.text = Label(header, text, "GameFontNormalLarge")
    header.text:SetPoint("LEFT")
    local line = header:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 1)
    line:SetGradient("HORIZONTAL", CreateColor(1, 0.82, 0, 0.67), CreateColor(1, 0.82, 0, 0))
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 2)
    line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 2)
    return header
end

-- A column's parts top to bottom, each with its own gap above it.
local function Stack(column)
    local y = column.top
    for _, part in ipairs(column) do
        y = y - (part.gap or 0)
        part:ClearAllPoints()
        part:SetPoint("LEFT", column.page, "TOPLEFT", part.inRow and column.x + COLUMN or column.x, y - 13)
        y = y - (part.height or 32)
    end
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

local MAKE = { checkbox = Checkbox, slider = Slider, dropdown = Dropdown, button = Button }

-- A page's title and its columns, from the rows in the settings list.
local function NewPage(parent, title)
    local page = New("Frame", parent)
    page:SetPoint("TOPLEFT", LIST + 4, -4)
    page:SetPoint("BOTTOMRIGHT", -4, 4)
    page.name = title
    page.title = Label(page, title, "GameFontHighlightLarge")
    page.title:SetPoint("TOPLEFT", LEFT, -14)
    page.columns = { { page = page, x = LEFT, top = -50 }, { page = page, x = RIGHT, top = -50 } }
    page.column, page.rows, page.parts = page.columns[1], {}, {}
    return page
end

-- The pages and which settings go on each; their controls are made when the
-- page is first shown (frames are never freed, so a page never opened costs nothing).
local function BuildPages(parent)
    local pages = { NewPage(parent, ADDON_NAME) }
    local page = pages[1]
    for _, row in ipairs(ns.SETTINGS) do
        if row.page then
            page = NewPage(parent, row.page)
            pages[#pages + 1] = page
        else
            page.rows[#page.rows + 1] = row
        end
    end
    return pages
end

local function BuildRows(page)
    if page.built then return end
    page.built = true
    for _, row in ipairs(page.rows) do
        if row.column then
            page.column = page.columns[row.column]
        elseif row.header then
            page.column[#page.column + 1] = Header(page, row.header)
        elseif not (row.forever and ns.IS_RETAIL) then
            local part = MAKE[row.kind](page, row)
            part.row = row
            page.column[#page.column + 1] = part
            page.parts[#page.parts + 1] = part
            if row.needsPrice and not ns.priceAddon then
                part:SetEnabled(false)
                if part.label then part.label:SetFontObject("GameFontDisable") end
                if not page.note then
                    page.note = Label(page, "Needs Auctionator, TradeSkillMaster, AuctionMaster or Blackthornes Tradeskills.", "GameFontRed")
                    page.note:SetPoint("LEFT", page.title, "RIGHT", 12, 0)
                end
            end
        end
    end
    for _, column in ipairs(page.columns) do Stack(column) end
end

-- A dropdown's label: the saved choice's name (nothing for a value it doesn't list).
local function ChoiceName(row)
    local value = ns.db[row.key]
    for _, choice in ipairs(row.choices()) do
        if choice[1] == value then return choice[2] end
    end
end

local function RefreshPage(page)
    BuildRows(page)
    refreshing = true
    for _, part in ipairs(page.parts) do
        local kind, key = part.row.kind, part.row.key
        if kind == "checkbox" then
            part:SetChecked(ns.db[key] == true)
        elseif kind == "slider" then
            part:SetValue(ns.db[key])
        elseif kind == "dropdown" then
            part:SetText(ChoiceName(part.row))
        end
    end
    refreshing = false
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function ListEntry(list, y, page)
    local item = New("Button", list)
    item:SetSize(LIST - 12, 22)
    item:SetPoint("TOPLEFT", 4, y)
    -- The picked row: the brown a shade lighter, bronze lines fading out above and
    -- below it, a gold bar at its left.
    item.selected = item:CreateTexture(nil, "BACKGROUND")
    item.selected:SetColorTexture(46 / 255, 38 / 255, 27 / 255)
    item.selected:SetAllPoints()
    item.picked = { item.selected }
    for _, edge in ipairs({ "TOP", "BOTTOM" }) do
        local line = item:CreateTexture(nil, "BORDER")
        line:SetPoint(edge .. "LEFT")
        line:SetPoint(edge .. "RIGHT")
        line:SetHeight(1)
        line:SetColorTexture(1, 1, 1, 1)
        line:SetGradient("HORIZONTAL", CreateColor(0.47, 0.39, 0.24, 1), CreateColor(0.47, 0.39, 0.24, 0))
        item.picked[#item.picked + 1] = line
    end
    item.bar = item:CreateTexture(nil, "BORDER")
    item.picked[#item.picked + 1] = item.bar
    item.bar:SetPoint("TOPLEFT")
    item.bar:SetPoint("BOTTOMLEFT")
    item.bar:SetWidth(3)
    item.bar:SetColorTexture(1, 0.82, 0)
    item:SetHighlightAtlas("Options_List_Hover")
    item.text = Label(item, page.name)
    item.text:SetPoint("LEFT", 10, 0)
    item:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
        window.page = page
        window.Refresh()
    end)
    return item
end

local function Build()
    window = New("Frame", UIParent, "ButtonFrameTemplate")
    window:Hide()
    window:SetSize(760 + LIST, 460)
    window:SetPoint("CENTER", 0, 20)
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:EnableMouse(true)
    -- Dragged by any empty part of it and kept on screen (back in the middle after a reload).
    window:SetMovable(true)
    window:SetClampedToScreen(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetTitle(C_AddOns.GetAddOnMetadata(ADDON_NAME, "Title") or ADDON_NAME)
    local logo = "Interface\\AddOns\\" .. ADDON_NAME .. "\\logo"
    window:SetPortraitToAsset(logo)
    -- The logo in the frame's own bronze ring, filling its hole, in place of the
    -- portrait (whose round mask sits off the ring's middle). Under the ring, as the
    -- portrait is.
    local corner = window.NineSlice and window.NineSlice.TopLeftCorner
    if corner then
        local size = corner:GetWidth()
        if not (size and size > 0) then size = 95 end
        window.PortraitContainer.portrait:Hide()
        local art = window.PortraitContainer:CreateTexture(nil, "OVERLAY")
        art:SetSize(size * 0.51, size * 0.51) -- (a little past the hole, under the ring)
        art:SetPoint("CENTER", corner, "TOPLEFT", size * 0.401, -size * 0.401) -- (the ring's middle in the art)
        art:SetTexture(logo)
        local mask = window.PortraitContainer:CreateMaskTexture()
        mask:SetAllPoints(art)
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        art:AddMaskTexture(mask)
        window.logo = art
    end
    ButtonFrameTemplate_HideButtonBar(window)
    window.CloseButton:SetScript("OnClick", function() window:Hide() end)
    window:SetScript("OnShow", function() PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end)
    window:SetScript("OnHide", function() PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE) end)
    -- The list and pages on the inset's stone with the logo's brown added over it (its
    -- grain kept, its average that brown), the strip under the title in that brown.
    window.backdrop = window.Inset:CreateTexture(nil, "BACKGROUND", nil, 7)
    window.backdrop:SetAllPoints()
    window.backdrop:SetColorTexture(14 / 255, 10 / 255, 5 / 255)
    window.backdrop:SetBlendMode("ADD")
    local strip = window:CreateTexture(nil, "BORDER", nil, 1)
    strip:SetPoint("TOPLEFT", 2, -21)
    strip:SetPoint("BOTTOMRIGHT", window, "TOPRIGHT", -2, -60)
    strip:SetColorTexture(BROWN[1], BROWN[2], BROWN[3])
    -- What's New in the strip's right end: gold words with a notes icon, white under the
    -- mouse, like a link. The version in the bottom right corner.
    local news = New("Button", window)
    news:SetPoint("RIGHT", window, "TOPRIGHT", -16, -40)
    local icon = news:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT")
    news.label = Label(news, GAMEMENU_NEW_BUTTON)
    news.label:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    news:SetSize(18 + 5 + news.label:GetStringWidth(), 22)
    news:SetScript("OnEnter", function() news.label:SetFontObject("GameFontHighlight") end)
    news:SetScript("OnLeave", function() news.label:SetFontObject("GameFontNormal") end)
    news:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        ns.ShowWhatsNew()
    end)
    window.news = news
    window.version = Label(window, ("%s %s"):format(GAME_VERSION_LABEL, C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or ""), "GameFontDisableSmall")
    window.version:SetPoint("BOTTOMRIGHT", -16, 12)

    -- The list on the left, a shade lighter, with a thin line beside it.
    local list = New("Frame", window.Inset)
    list:SetPoint("TOPLEFT", 2, -2)
    list:SetPoint("BOTTOMLEFT", 2, 2)
    list:SetWidth(LIST - 2)
    local panel = list:CreateTexture(nil, "BACKGROUND", nil, -1)
    panel:SetAllPoints()
    panel:SetColorTexture(7 / 255, 5 / 255, 4 / 255)
    panel:SetBlendMode("ADD")
    local divider = list:CreateTexture(nil, "BORDER")
    divider:SetPoint("TOPRIGHT")
    divider:SetPoint("BOTTOMRIGHT")
    divider:SetWidth(1)
    divider:SetColorTexture(70 / 255, 58 / 255, 40 / 255)

    window.pages, window.list = BuildPages(window.Inset), {}
    for i, page in ipairs(window.pages) do window.list[i] = ListEntry(list, -6 - (i - 1) * 24, page) end
    window.page = window.pages[1]

    function window.Refresh()
        for i, page in ipairs(window.pages) do
            local shown = page == window.page
            page:SetShown(shown)
            for _, part in ipairs(window.list[i].picked) do part:SetShown(shown) end
            window.list[i].text:SetFontObject(shown and "GameFontHighlight" or "GameFontNormal")
        end
        RefreshPage(window.page)
    end

    -- Closes with the options window it may have been opened from.
    if SettingsPanel and SettingsPanel.HookScript then
        SettingsPanel:HookScript("OnHide", function() window:Hide() end)
    end
end

local function Open()
    if not window then Build() end
    window:Show()
    window.Refresh()
end

-- If opening it errors, the error is still reported, the window stays shut, and
-- from the next reload this version's settings are Blizzard's rows in the options.
local failed
local function ShowSettingsWindow()
    if failed then return end
    failed = not xpcall(Open, geterrorhandler())
    if failed then
        ns.db.settingsWindowFailed = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
        if window then window:Hide() end
    end
end

ns.ShowSettingsWindow = ShowSettingsWindow
