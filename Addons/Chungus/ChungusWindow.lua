-- Chungus (window shell) — the /chungus frame: title, tab bar, page host.
-- Tabs come from Addon.Tabs (registered modules) plus grayed placeholders for
-- installed-but-unloaded Chungus* addons. Each tab shows a page frame created
-- by its module (createPage) or a "not loaded" placeholder.

local AddonName, Addon = ...

local Chungus = _G.Chungus
local API = Chungus.API

-- ------------------------------------------------------------------
-- Shared widget builders (used by every module's tab page).
-- ------------------------------------------------------------------
function Addon.MakeButton(parent, name, w, h, label)
	local btn = CreateFrame("BUTTON", name, parent, "UIPanelButtonTemplate")
	btn:SetSize(w, h)
	btn:SetText(label)
	return btn
end

function Addon.MakeEditBox(parent, name, w)
	local box = CreateFrame("EDITBOX", name, parent, "InputBoxTemplate")
	box:SetSize(w, 20)
	box:SetAutoFocus(false)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	return box
end

function Addon.MakeLabel(parent, text, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetText(text)
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

-- ------------------------------------------------------------------
-- Column layout kit. One Column per visual column of a page; it stacks rows
-- vertically and anchors widgets inside them, so nothing can overlap by
-- construction. page.NewColumn is created by ChungusProfiles etc. as:
--   local left = Addon.NewColumn(page, 0)
--   left:Add(widget, height, gap)          -- own full-width line
--   local y = left:Reserve(h, gap)         -- multi-widget row: reserve space...
--   left:Place(widget, dx, y)              -- ...then anchor each at dx offsets
-- ------------------------------------------------------------------
function Addon.NewColumn(page, x)
	local col = { page = page, x = x or 0, y = 0 }
	function col:Reserve(height, gap)
		local y = self.y
		self.y = self.y + (height or 22) + (gap or 8)
		return y
	end
	function col:Place(widget, dx, y)
		widget:ClearAllPoints()
		widget:SetPoint("TOPLEFT", self.page, "TOPLEFT", self.x + (dx or 0), -(y))
	end
	function col:Add(widget, height, gap, dx)
		local y = self:Reserve(height, gap)
		self:Place(widget, dx or 0, y)
		return widget
	end
	return col
end

-- ------------------------------------------------------------------
-- Window.
-- ------------------------------------------------------------------
local Window = CreateFrame("FRAME", "_ChungusWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
Window:SetSize(620, 480)
Window:SetPoint("CENTER")
Window:SetMovable(true)
Window:EnableMouse(true)
Window:RegisterForDrag("LeftButton")
Window:SetScript("OnDragStart", Window.StartMoving)
Window:SetScript("OnDragStop", Window.StopMovingOrSizing)
if Window.SetBackdrop then
	Window:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	Window:SetBackdropColor(0, 0, 0, 0.9)
end
tinsert(UISpecialFrames, "_ChungusWindow")  -- ESC closes
Window:Hide()

-- Resizable: drag the bottom-right corner. Size is remembered account-wide.
-- WoW 10.0 renamed the resize-bounds API to SetResizeBounds; older clients
-- use SetMinResize/SetMaxResize, so try both and never assume either exists.
if Window.SetClampedToScreen then Window:SetClampedToScreen(true) end
if Window.SetResizable then Window:SetResizable(true) end
if Window.SetResizeBounds then
	Window:SetResizeBounds(660, 400, 1900, 1400)
else
	if Window.SetMinResize then Window:SetMinResize(660, 400) end
	if Window.SetMaxResize then Window:SetMaxResize(1900, 1400) end
end

function Addon.ApplyWindowSize()
	local ui = API.GetUISettings()
	Window:SetSize(ui.windowWidth, ui.windowHeight)
end

function Addon.SaveWindowSize()
	local ui = API.GetUISettings()
	ui.windowWidth = math.floor((Window:GetWidth() or 0) + 0.5)
	ui.windowHeight = math.floor((Window:GetHeight() or 0) + 0.5)
end

Addon.ApplyWindowSize()

Window.title = Window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
Window.title:SetPoint("TOP", 0, -16)
Window.title:SetText("Chungus")

local closeBtn = CreateFrame("BUTTON", nil, Window, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", Window, "TOPRIGHT", -4, -4)

-- Drag handle for resizing (bottom-right).
local resizeGrip = CreateFrame("BUTTON", nil, Window)
resizeGrip:SetSize(16, 16)
resizeGrip:SetPoint("BOTTOMRIGHT", Window, "BOTTOMRIGHT", -4, 4)
resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeGrip:SetScript("OnMouseDown", function(self, button)
	if button ~= "LeftButton" then return end
	if type(Window.StartSizing) == "function" then
		Window:StartSizing("BOTTOMRIGHT")
	else
		-- Manual fallback for clients without StartSizing.
		local cx, cy = GetCursorPosition()
		local scale = Window:GetEffectiveScale() or 1
		self.__startX, self.__startY = cx / scale, cy / scale
		self.__startW, self.__startH = Window:GetWidth(), Window:GetHeight()
		self.__dragging = true
	end
end)
resizeGrip:SetScript("OnMouseUp", function()
	if type(Window.StopMovingOrSizing) == "function" then
		Window:StopMovingOrSizing()
	end
	resizeGrip.__dragging = nil
	Addon.SaveWindowSize()
end)
resizeGrip:SetScript("OnUpdate", function(self)
	if not self.__dragging then return end
	local cx, cy = GetCursorPosition()
	local scale = Window:GetEffectiveScale() or 1
	local w = self.__startW + (cx / scale - self.__startX)
	local h = self.__startH - (cy / scale - self.__startY)
	if w < 660 then w = 660 end
	if w > 1900 then w = 1900 end
	if h < 400 then h = 400 end
	if h > 1400 then h = 1400 end
	Window:SetSize(w, h)
end)
resizeGrip:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("Drag to resize", 1, 0.82, 0)
	GameTooltip:AddLine("The window size is remembered.", 0.9, 0.9, 0.9)
	GameTooltip:Show()
end)
resizeGrip:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Page host: one page frame per tab, all filling this area.
local pagesHost = CreateFrame("FRAME", nil, Window)
pagesHost:SetPoint("TOPLEFT", Window, "TOPLEFT", 24, -70)
pagesHost:SetPoint("BOTTOMRIGHT", Window, "BOTTOMRIGHT", -24, 22)

-- ------------------------------------------------------------------
-- Options tab — layout preferences shared by every tab and profile.
-- ------------------------------------------------------------------
local function BuildOptionsPage(page)
	local y = 0
	local refreshers = {}

	local heading = Addon.MakeLabel(page, "Layout (account-wide)")
	heading:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -2)
	heading:SetTextColor(1, 0.82, 0)

	local STEP_LIMITS = {
		padding = { 0, 32 },
		rowGap = { 0, 20 },
		fontSize = { 9, 18 },
	}

	local function Stepper(labelText, key, step)
		y = y + 30
		local row = CreateFrame("FRAME", nil, page)
		row:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -y)
		row:SetSize(420, 20)

		local minus = Addon.MakeButton(row, nil, 22, 20, "-")
		minus:SetPoint("LEFT", row, "LEFT", 0, 0)
		local plus = Addon.MakeButton(row, nil, 22, 20, "+")
		plus:SetPoint("LEFT", row, "LEFT", 26, 0)
		local label = Addon.MakeLabel(row, labelText)
		label:SetPoint("LEFT", row, "LEFT", 56, 0)
		local value = Addon.MakeLabel(row, "")
		value:SetPoint("LEFT", row, "LEFT", 236, 0)
		value:SetTextColor(1, 0.82, 0)

		local function Refresh()
			value:SetText(tostring(API.GetUISettings()[key]))
		end
		local function Bump(delta)
			local ui = API.GetUISettings()
			local limits = STEP_LIMITS[key] or { 0, 100 }
			local newValue = (ui[key] or limits[1]) + delta
			if newValue < limits[1] then newValue = limits[1] end
			if newValue > limits[2] then newValue = limits[2] end
			ui[key] = newValue
			Refresh()
			Addon.RelayoutPages()
		end
		minus:SetScript("OnClick", function() Bump(-step) end)
		plus:SetScript("OnClick", function() Bump(step) end)
		Refresh()
		refreshers[#refreshers + 1] = Refresh
	end

	Stepper("Page padding", "padding", 2)
	Stepper("Row spacing", "rowGap", 2)
	Stepper("Font size", "fontSize", 1)

	y = y + 34
	local resetLayout = Addon.MakeButton(page, nil, 140, 20, "Reset layout")
	resetLayout:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -y)
	resetLayout:SetScript("OnClick", function()
		local ui = API.GetUISettings()
		ui.padding = API.UI_DEFAULTS.padding
		ui.rowGap = API.UI_DEFAULTS.rowGap
		ui.fontSize = API.UI_DEFAULTS.fontSize
		for _, refresh in ipairs(refreshers) do refresh() end
		Addon.RelayoutPages()
	end)

	local resetSize = Addon.MakeButton(page, nil, 140, 20, "Reset window size")
	resetSize:SetPoint("TOPLEFT", page, "TOPLEFT", 156, -y)
	resetSize:SetScript("OnClick", function()
		local ui = API.GetUISettings()
		ui.windowWidth = API.UI_DEFAULTS.windowWidth
		ui.windowHeight = API.UI_DEFAULTS.windowHeight
		Addon.ApplyWindowSize()
	end)

	y = y + 34
	local note = Addon.MakeLabel(page,
		"Drag the bottom-right corner of the window to resize it.\n"
		.. "These preferences are shared by every profile and character.")
	note:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -y)
	note:SetJustifyH("LEFT")
	note:SetSpacing(2)
	note:SetTextColor(0.65, 0.65, 0.65)
end

-- ------------------------------------------------------------------
-- Tab list: registered modules first, then grayed entries for every installed
-- Chungus* addon that did not register (disabled, failed, or not written yet).
-- ------------------------------------------------------------------
local function BuildTabList()
	local tabs = {}
	local seen = {}
	for _, tab in ipairs(Addon.Tabs) do
		tinsert(tabs, tab)
		seen[tab.key] = true
	end
	for _, a in ipairs(API.GetInstalledAddons(false)) do
		if a.name ~= "Chungus"
			and string.sub(a.name, 1, 8) == "Chungus"
			and not a.loaded and not seen[a.name] then
			seen[a.name] = true
			tinsert(tabs, { key = a.name, title = a.name, addonName = a.name, module = nil })
		end
	end
	-- Options is a window feature, not a module addon: append it last so it
	-- never shows up as a per-profile module checkbox.
	tinsert(tabs, { key = "options", title = "Options", addonName = AddonName,
		module = { key = "options", createPage = BuildOptionsPage } })
	return tabs
end

Addon.GetTabList = BuildTabList

-- ------------------------------------------------------------------
-- Tab bar (pooled buttons).
-- ------------------------------------------------------------------
local tabButtons = {}

local function BuildTabBar()
	local tabs = BuildTabList()
	local active = Addon.ui.activeTab
	local activeFound = false
	for i = 1, 8 do
		local tab = tabs[i]
		local btn = tabButtons[i]
		if tab then
			if tab.key == active then activeFound = true end
			if not btn then
				btn = Addon.MakeButton(Window, nil, 92, 22, "")
				btn:SetPoint("TOPLEFT", Window, "TOPLEFT", 24 + (i - 1) * 96, -40)
				btn:SetNormalFontObject("GameFontNormalSmall")
				btn:SetFrameLevel(Window:GetFrameLevel() + 2)
				btn:SetScript("OnClick", function(self)
					Addon.ui.activeTab = self.tabKey
					Addon.RefreshUI()
				end)
				btn:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
					GameTooltip:SetText(tostring(self.tabTitle), 1, 0.82, 0)
					if not self.tabLoaded then
						GameTooltip:AddLine("Module addon not loaded.", 0.8, 0.6, 0.4)
						GameTooltip:AddLine("Enable it and /reload.", 0.8, 0.8, 0.8)
					end
					GameTooltip:Show()
				end)
				btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
				tabButtons[i] = btn
			end
			btn.tabKey = tab.key
			btn.tabTitle = tab.title
			btn.tabLoaded = tab.module ~= nil
			if tab.key == active then
				btn:SetText("|cffffd100[" .. tab.title .. "]|r")
			elseif tab.module then
				btn:SetText(tab.title)
			else
				btn:SetText("|cff777777" .. tab.title .. "|r")
			end
			btn:Show()
		elseif btn then
			btn.tabKey = nil
			btn:Hide()
		end
	end
	if not activeFound then
		local fallback = tabs[1] and tabs[1].key or nil
		-- Options exists even before any module registers; never let it become
		-- the startup tab, or the window would open there on first show.
		if fallback == "options" and #tabs == 1 then fallback = nil end
		Addon.ui.activeTab = fallback
	end
end

-- ------------------------------------------------------------------
-- Pages. Created lazily by the module's createPage, or a placeholder for
-- unloaded modules. page.render is called on every refresh.
-- ------------------------------------------------------------------
function Addon.EnsurePage(tab)
	local page = Addon.ui.pages and Addon.ui.pages[tab.key]
	if page then return page end
	Addon.ui.pages = Addon.ui.pages or {}
	page = CreateFrame("FRAME", nil, pagesHost)
	page:SetAllPoints(pagesHost)
	if tab.module and tab.module.createPage then
		local ok, err = pcall(tab.module.createPage, page)
		if not ok then
			print("[Chungus] tab '" .. tab.key .. "' content error: " .. tostring(err))
			local fs = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("TOPLEFT", 12, -14)
			fs:SetJustifyH("LEFT")
			fs:SetText("This module failed to build its page:\n" .. tostring(err))
			fs:SetTextColor(1, 0.4, 0.4)
		end
	else
		local fs = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		fs:SetPoint("TOPLEFT", 12, -14)
		fs:SetJustifyH("LEFT")
		fs:SetSpacing(2)
		fs:SetText(tab.title .. " is not loaded.\nEnable this addon in the character screen and /reload.")
		fs:SetTextColor(0.9, 0.7, 0.5)
	end
	page:Hide()
	Addon.ui.pages[tab.key] = page
	return page
end

-- ------------------------------------------------------------------
-- Refresh: rebuild tab bar, show only the active page, call its render.
-- ------------------------------------------------------------------
-- Re-apply a page's layout after a UI preference changed (padding, spacing,
-- font size). Pages opt in by defining page.layout.
function Addon.RelayoutPages()
	for _, page in pairs(Addon.ui.pages or {}) do
		if page.layout then
			local ok, err = pcall(page.layout, page)
			if not ok then print("[Chungus] layout error: " .. tostring(err)) end
		end
	end
end

function Addon.RefreshUI()
	BuildTabBar()
	local key = Addon.ui.activeTab
	local page
	if key then
		for _, tab in ipairs(BuildTabList()) do
			if tab.key == key then page = Addon.EnsurePage(tab) end
		end
	end
	Addon.ui.pages = Addon.ui.pages or {}
	for _, p in pairs(Addon.ui.pages) do
		if p ~= page then p:Hide() end
	end
	if page then
		page:Show()
		if page.render then
			local ok, err = pcall(page.render)
			if not ok then print("[Chungus] tab render error: " .. tostring(err)) end
		end
	end
end

function Addon.ToggleWindow()
	if Window:IsShown() then
		Window:Hide()
	else
		Addon.RefreshUI()
		Window:Show()
	end
end

Window:SetScript("OnShow", function() Addon.RefreshUI() end)

-- Initial build. Wrapped so a failure can never kill ToggleWindow (that made
-- /chungusp go silent in v1).
local okInit, errInit = pcall(Addon.RefreshUI)
if not okInit then
	print("[Chungus] window init failed: " .. tostring(errInit))
else
	print("[Chungus] UI ready. /chungus opens the profile window.")
end
