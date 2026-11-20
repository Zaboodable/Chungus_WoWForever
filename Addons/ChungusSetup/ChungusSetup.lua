-- Chungus Setup (module of Chungus) — the "Setup" tab.
--
-- Edits, per selected profile, the list of actions that apply OTHER addons'
-- settings when that profile is applied:
--   API  — pick an addon, then a function, then its arguments.
--          Addons with profiles get "switch profile" first, with a dropdown of
--          their real profile names. Support is discovered at runtime:
--            * AceDB addons (Bartender4, Plater, Questie...) via the shared
--              AceDB registry;
--            * addons exposing their own profile functions
--              (Config.GetProfileNames / Config.ChangeProfile), including ones
--              whose API is only reachable through a closure;
--            * addons that keep profiles in saved variables
--              (ADDON_CONFIG.Profiles + ADDON_CURRENT_PROFILE) - those apply
--              on the next /reload.
--          Every callable function of the chosen addon is enumerated for the
--          function dropdown, scoped to that addon only.
--   CMD  — slash command (e.g. "/details profile set PvP")
--   SNAP — restore a saved-variable snapshot (CAP captures it first; /reload to apply)
--
-- Every row has a Run button to execute that single action immediately
-- (testing), and Run All fires the whole list the same way an apply does.
-- Run never changes the applied profile - it is purely a test button.
--
-- "$profile" in an argument means "the Chungus profile being applied", so a
-- row with $profile switches each addon to the profile of the same name.
--
-- Data lives in the profile itself: profile.moduleData.ChungusSetup.actions.
--
-- The row list is a scrollable, pooled list: any number of actions fits, and
-- rows are created on demand. Padding, row spacing and font size come from
-- the window's Options tab (API.GetUISettings) via page.layout, which the
-- window calls again whenever one of those preferences changes.
--
-- NOTE: the second vararg of an addon file is PER-ADDON. This child module
-- reaches the core's shared table through Chungus.Core, never through its own
-- local Addon.

local AddonName, Addon = ...

local Chungus = _G.Chungus
local Core = Chungus.Core
local API = Chungus.API
local G = _G
local MakeButton = Core.MakeButton
local MakeEditBox = Core.MakeEditBox
local MakeLabel = Core.MakeLabel

-- Get (or create) this module's data section inside a profile.
local function GetData(profile)
	profile.moduleData = profile.moduleData or {}
	local data = profile.moduleData.ChungusSetup
	if type(data) ~= "table" then data = {}; profile.moduleData.ChungusSetup = data end
	if type(data.actions) ~= "table" then data.actions = {} end
	return data
end

-- ------------------------------------------------------------------
-- Apply: run every action of the profile, staggered (commands need the
-- previous one to finish before the next goes in). Also used by Run All.
-- ------------------------------------------------------------------
local function OnApply(profileName)
	local profile = API.GetProfile(profileName)
	if not profile then return end
	-- Make sure every loaded AceDB addon has a handler before the rows run.
	if API.RegisterAceHandlers then API.RegisterAceHandlers() end
	local actions = GetData(profile).actions
	for i, action in ipairs(actions) do
		Core.RunAfter(0.2 + (i - 1) * 0.3, function()
			API.RunAction(profileName, action)
		end)
	end
end

-- ------------------------------------------------------------------
-- Browser popup factory: filter box + scrollable, clickable item list.
-- Caller supplies GetItems() -> { {label, data}, ... } and OnClick(item).
-- Scrolling: mouse wheel or the < / > buttons; filter matches every word typed.
-- ------------------------------------------------------------------
local function MakeBrowserPopup(page, globalName, headerText)
	local popup = CreateFrame("FRAME", globalName, page, BackdropTemplateMixin and "BackdropTemplate" or nil)
	popup:SetSize(300, 300)
	if popup.SetBackdrop then
		popup:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		popup:SetBackdropColor(0, 0, 0, 0.95)
	end
	popup:SetFrameLevel(page:GetFrameLevel() + 20)
	popup:EnableMouse(true)
	popup:Hide()
	popup.offset = 0
	popup.filterText = ""

	popup.filter = MakeEditBox(popup, nil, 200)
	popup.filter:SetPoint("TOPLEFT", popup, "TOPLEFT", 18, -22)
	popup.filter:SetScript("OnTextChanged", function(self)
		popup.filterText = string.lower((self:GetText() or ""):match("^%s*(.-)%s*$") or "")
		popup.offset = 0
		popup:Fill()
	end)

	popup.header = MakeLabel(popup, headerText)
	popup.header:SetPoint("TOPLEFT", popup.filter, "BOTTOMLEFT", 0, -6)

	local closeBtn = CreateFrame("BUTTON", nil, popup, "UIPanelCloseButton")
	closeBtn:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -4, -4)

	local ROWS = 11
	local rows = {}
	for i = 1, ROWS do
		local btn = CreateFrame("BUTTON", nil, popup)
		btn:SetSize(250, 18)
		btn:SetPoint("TOPLEFT", popup, "TOPLEFT", 22, -(48 + (i - 1) * 20))
		local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", 0, 0)
		fs:SetJustifyH("LEFT")
		btn:SetFontString(fs)
		btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		btn:SetScript("OnClick", function(self)
			if self.item and popup.OnClick then popup.OnClick(self.item) end
		end)
		rows[i] = btn
	end

	popup.counter = MakeLabel(popup, "", "CENTER")
	popup.counter:SetPoint("BOTTOM", popup, "BOTTOM", 0, 16)
	local prevBtn = MakeButton(popup, nil, 20, 16, "<")
	prevBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 22, 12)
	prevBtn:SetNormalFontObject("GameFontNormalSmall")
	prevBtn:SetScript("OnClick", function()
		popup.offset = popup.offset - ROWS
		popup:Fill()
	end)
	local nextBtn = MakeButton(popup, nil, 20, 16, ">")
	nextBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -22, 12)
	nextBtn:SetNormalFontObject("GameFontNormalSmall")
	nextBtn:SetScript("OnClick", function()
		popup.offset = popup.offset + ROWS
		popup:Fill()
	end)

	-- Filter matches when EVERY typed word appears in the item label.
	function popup:FilteredItems()
		local items = self.GetItems and self.GetItems() or {}
		local words = {}
		for w in (self.filterText or ""):gmatch("%S+") do tinsert(words, string.lower(w)) end
		local out = {}
		for _, item in ipairs(items) do
			local label = string.lower(item.label or "")
			local ok = true
			for _, w in ipairs(words) do
				if not string.find(label, w, 1, true) then
					ok = false
					break
				end
			end
			if ok then tinsert(out, item) end
		end
		return out
	end

	function popup:Fill()
		local items = self:FilteredItems()
		local n = #items
		local maxOffset = math.max(0, math.ceil(n / ROWS) - 1) * ROWS
		if self.offset > maxOffset then self.offset = maxOffset end
		if self.offset < 0 then self.offset = 0 end
		for i = 1, ROWS do
			local item = items[self.offset + i]
			local row = rows[i]
			if item then
				row.item = item
				row:SetText(item.label)
				row:Show()
			else
				row.item = nil
				row:Hide()
			end
		end
		if n > 0 then
			popup.counter:SetText(("%d-%d of %d"):format(self.offset + 1, math.min(self.offset + ROWS, n), n))
		else
			popup.counter:SetText("0 of 0")
		end
	end

	-- mouse wheel paging
	popup:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then
			self.offset = self.offset - ROWS
		else
			self.offset = self.offset + ROWS
		end
		self:Fill()
	end)

	function popup:Open(prefill, anchor)
		self.filterText = string.lower(prefill or "")
		self.filter:SetText(self.filterText)
		self.offset = 0
		self:ClearAllPoints()
		-- Place just below the control that opened it, clamped so the panel
		-- always stays inside the page (rows near the bottom would otherwise
		-- push it off-screen).
		local popupHeight = 300
		local pageHeight = 388
		if page.GetHeight then
			local hok, h = pcall(page.GetHeight, page)
			if hok and type(h) == "number" and h > popupHeight + 16 then pageHeight = h end
		end
		local y = 0
		if anchor and anchor.GetTop and page.GetTop then
			local pok, pageTop = pcall(page.GetTop, page)
			local aok, anchorTop = pcall(anchor.GetTop, anchor)
			if pok and aok and pageTop and anchorTop then
				y = pageTop - anchorTop + 4
			end
		end
		local maxY = pageHeight - popupHeight - 8
		if maxY < 0 then maxY = 0 end
		if y < 0 then y = 0 end
		if y > maxY then y = maxY end
		self:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -y)
		self:Show()
		self:Fill()
		if self.filter and self.filter.SetFocus then
			self.filter:SetFocus()
		end
	end

	return popup
end

-- ------------------------------------------------------------------
-- The Setup tab page.
-- ------------------------------------------------------------------
API.RegisterTab("setup", "Setup", "ChungusSetup", function(page)

	-- ------------------------------------------------------------------
	-- Browsers.
	-- ------------------------------------------------------------------
	local cmdBrowser = MakeBrowserPopup(page, "_ChungusCmdBrowser", "Detected slash commands (click to insert)")
	cmdBrowser.GetItems = function()
		local t = {}
		for _, c in ipairs(API.GetSlashCommands(true)) do
			tinsert(t, { label = c, data = c })
		end
		return t
	end
	cmdBrowser.OnClick = function(item)
		local target = Core.ui.lastCmdBox
		if target and item.data then
			local text = target:GetText() or ""
			if text ~= "" and string.sub(text, -1) ~= " " then text = text .. " " end
			target:SetText(text .. item.data)
			target:SetFocus()
		end
		cmdBrowser:Hide()
	end

	-- Pickers are dropdowns anchored under the control that opened them. Each
	-- one edits Core.ui.pickerAction (the row whose dropdown was clicked).
	local addonPicker = MakeBrowserPopup(page, "_ChungusAddonPicker",
		"Addon - type to search every loaded addon")
	addonPicker.GetItems = function()
		local t, seen = {}, {}
		-- Anything Chungus can switch profiles on: AceDB, known providers and
		-- addons detected at runtime (their own Config API or savedvars).
		for _, target in ipairs(API.GetProfileTargets(false, true)) do
			if not seen[target.key] then
				seen[target.key] = true
				local suffix = target.source == "savedvar" and "  [reload]" or ""
				tinsert(t, {
					label = "profile  " .. target.label
						.. "  (" .. tostring(target.current or "?") .. ")" .. suffix,
					data = { addon = target.key },
				})
			end
		end
		-- Curated handlers that are not already covered (Details).
		for _, name in ipairs(API.GetHandlerNames()) do
			if not seen[name] then
				seen[name] = true
				tinsert(t, { label = "handler  " .. name, data = { addon = name } })
			end
		end
		-- Everything else only when searching: keeps the list short by default.
		local searching = (addonPicker.filterText or "") ~= ""
		if searching then
			for _, a in ipairs(API.GetInstalledAddons(true)) do
				if not seen[a.name] and type(G[a.name]) == "table" then
					seen[a.name] = true
					tinsert(t, { label = "addon    " .. a.name, data = { addon = a.name } })
				end
			end
		else
			tinsert(t, { label = "(type to search all loaded addons)", data = nil })
		end
		return t
	end
	addonPicker.OnClick = function(item)
		local action = Core.ui.pickerAction
		if item.data and item.data.addon and action then
			action.addon = item.data.addon
			if type(action.args) ~= "table" then action.args = { "$profile" } end
			action.profile = nil
			-- Pre-select a sane function for this addon.
			action.member = ""
			Core.RefreshUI()
		end
		addonPicker:Hide()
	end

	local funcPicker = MakeBrowserPopup(page, "_ChungusFuncPicker",
		"Function - type to search every key")
	funcPicker.GetItems = function()
		local action = Core.ui.pickerAction
		local addonName = action and action.addon or ""
		if addonName == "" then
			return { { label = "pick an addon first", data = nil } }
		end
		local t = {}
		local prof = API.GetAddonProfiles(addonName)
		if not prof then
			tinsert(t, { label = "no profile API for " .. addonName
				.. " - pick a function below", data = nil })
		end
		local useful = API.GetAddonFunctions(addonName)
		local shown = 0
		for _, f in ipairs(useful) do
			if shown >= 40 and (funcPicker.filterText or "") == "" then
				tinsert(t, { label = "(" .. (#useful - shown) .. " more - type to search)", data = nil })
				break
			end
			shown = shown + 1
			local params = f.names and #f.names > 0
				and ("(" .. table.concat(f.names, ", ") .. ")") or "()"
			local suffix = ""
			if f.member == "" and prof and prof.requiresReload then
				suffix = "  [applies on /reload]"
			end
			tinsert(t, { label = f.label .. "  " .. params .. suffix,
				data = { member = f.member, params = f.params } })
		end
		-- Typing searches the plumbing too (RegisterModule, Ace hooks...).
		if (funcPicker.filterText or "") ~= "" then
			local obj = G[addonName]
			if type(obj) == "table" then
				local shown = {}
				for _, f in ipairs(useful) do shown[f.member] = true end
				local extra = {}
				for name, value in pairs(obj) do
					if type(name) == "string" and type(value) == "function"
						and not shown[name] then
						tinsert(extra, name)
					end
				end
				table.sort(extra)
				for _, name in ipairs(extra) do
					local desc = API.DescribeFunction(addonName, name)
					tinsert(t, { label = name .. "  (plumbing)",
						data = { member = name, params = desc.params } })
				end
			end
		end
		return t
	end
	funcPicker.OnClick = function(item)
		local action = Core.ui.pickerAction
		if item.data and action then
			action.member = item.data.member or ""
			local count = tonumber(item.data.params) or 1
			local names = API.DescribeFunction(action.addon, action.member).names
			action.args = action.args or {}
			for i = 1, count do
				if action.args[i] == nil then action.args[i] = (i == 1) and "$profile" or "" end
			end
			for i = #action.args, count + 1, -1 do action.args[i] = nil end
			action.paramNames = names
			Core.RefreshUI()
		end
		funcPicker:Hide()
	end

	local profilePicker = MakeBrowserPopup(page, "_ChungusProfilePicker",
		"Profiles - blank/$profile = same name as Chungus profile")
	profilePicker.GetItems = function()
		local action = Core.ui.pickerAction
		local addonName = action and action.addon or ""
		local t = {}
		if addonName == "" then return { { label = "pick an addon first", data = nil } } end
		local prof = API.GetAddonProfiles(addonName)
		tinsert(t, { label = "$profile  (same name as this Chungus profile)",
			data = { value = "$profile" } })
		if not prof then
			tinsert(t, { label = "this addon has no profile list - type a name",
				data = nil })
			return t
		end
		for _, name in ipairs(prof.list) do
			local active = (name == prof.current) and "  (active)" or ""
			tinsert(t, { label = name .. active, data = { value = name } })
		end
		return t
	end
	profilePicker.OnClick = function(item)
		local action = Core.ui.pickerAction
		if item.data and action then
			action.args = action.args or { "$profile" }
			action.args[1] = item.data.value
			action.profile = nil
			Core.RefreshUI()
		end
		profilePicker:Hide()
	end

	-- ------------------------------------------------------------------
	-- Header row.
	-- ------------------------------------------------------------------
	local editingLabel = MakeLabel(page, "No profile selected - pick one in the Profiles tab")
	editingLabel:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -2)

	local commandsBtn = MakeButton(page, nil, 84, 20, "Commands...")
	commandsBtn:SetPoint("TOPRIGHT", page, "TOPRIGHT", -64, -2)
	commandsBtn:SetScript("OnClick", function()
		if cmdBrowser:IsShown() then
			cmdBrowser:Hide()
		else
			-- prefilter from the focused command box: "/det..." -> "det"
			local pre = ""
			local target = Core.ui.lastCmdBox
			if target then
				local word = (target:GetText() or ""):match("^/(%S+)")
				if word then pre = string.lower(word) end
			end
			cmdBrowser:Open(pre, Core.ui.lastCmdBox)
		end
	end)

	-- ------------------------------------------------------------------
	-- Action rows (pooled), stacked below the header. Each control carries a
	-- tiny label underneath.
	--   CMD : command box (+ Commands... inserts into the focused box)
	--   API : [addon ▾] [function ▾] [arg1 (+profile ▾)] [arg2] [arg3]
	--   SNAP: savedvar box + [CAP]
	-- ------------------------------------------------------------------
	local KIND_LABELS = { cmd = "CMD", api = "API", snap = "SNAP" }

	local X_KIND, W_KIND = 0, 40
	local X_ADDON, W_ADDON = 44, 116
	local X_FUNC, W_FUNC = 164, 104
	local X_ARG1, W_ARG1 = 266, 68
	local X_ARG1DD, W_ARG1DD = 336, 14
	local X_ARG2, W_ARG2 = 352, 40
	local X_ARG3, W_ARG3 = 394, 40
	local X_ARG4, W_ARG4 = 436, 40
	local X_PLUS, W_PLUS = 478, 20
	local X_RUN = 502
	local X_DEL, W_DEL = 534, 22
	local ROW_WIDTH = X_DEL + W_DEL
	local LABEL_DY = 22      -- each control gets a label underneath
	local MAX_ROWS = 200

	-- Rows live in 'content', inside a scroll frame, so any number of them
	-- fits regardless of the window height. The header stays pinned above.
	local scroll = CreateFrame("ScrollFrame", "_ChungusActionsScroll", page,
		"UIPanelScrollFrameTemplate")
	local content = CreateFrame("FRAME", nil, scroll)
	content:SetSize(ROW_WIDTH, 1)
	scroll:SetScrollChild(content)
	scroll:EnableMouseWheel(true)

	local visibleRows = 0

	local function ScrollBar()
		return scroll.ScrollBar or _G["_ChungusActionsScrollScrollBar"]
	end

	local function MaxScroll()
		return math.max(0, (content:GetHeight() or 0) - (scroll:GetHeight() or 0))
	end

	local function SetScroll(value)
		if value < 0 then value = 0 end
		local maxScroll = MaxScroll()
		if value > maxScroll then value = maxScroll end
		scroll:SetVerticalScroll(value)
		local bar = ScrollBar()
		if bar and bar.SetValue then bar:SetValue(value) end
	end

	scroll:SetScript("OnMouseWheel", function(self, delta)
		SetScroll((self:GetVerticalScroll() or 0) - (delta or 0) * 36)
	end)

	local fontTargets = {}
	local function TrackFont(object, isButton)
		fontTargets[#fontTargets + 1] = { object = object, isButton = isButton and true or false }
	end

	local function ApplyFonts()
		local size = API.GetUISettings().fontSize
		local font = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
		for _, entry in ipairs(fontTargets) do
			local fs = entry.object
			if entry.isButton and fs.GetFontString then fs = fs:GetFontString() end
			if fs and fs.SetFont then
				local ok = pcall(fs.SetFont, fs, font, size, "")
				if not ok then pcall(fs.SetFont, fs, font, size) end
			end
		end
	end

	local function UpdateContent()
		local ui = API.GetUISettings()
		local step = LABEL_DY + ui.fontSize + ui.rowGap
		content:SetWidth(math.max(ROW_WIDTH, (scroll:GetWidth() or 0) - 20))
		content:SetHeight(math.max(1, visibleRows * step + 4))
		local bar = ScrollBar()
		if bar then
			local maxScroll = MaxScroll()
			bar:SetMinMaxValues(0, maxScroll)
			bar:SetValue(math.min(scroll:GetVerticalScroll() or 0, maxScroll))
		end
		SetScroll(scroll:GetVerticalScroll() or 0)
	end

	scroll:SetScript("OnSizeChanged", function() UpdateContent() end)

	local function CurrentAction(row)
		local profile = API.GetProfile(Core.ui.selected)
		if not profile or not row.index then return nil end
		return GetData(profile).actions[row.index]
	end

	local function ArgLabel(action, index)
		local names = action.paramNames
		if index == 1 and (not names or not names[1]) then
			return "profile arg (blank = $profile)"
		end
		local name = names and names[index]
		return name and ("argument " .. index .. " (" .. name .. ")") or ("argument " .. index)
	end

	local function RefreshRowVisuals(row, action)
		local kind = action.kind or "cmd"
		row.kindBtn:SetText(KIND_LABELS[kind] or kind)
		-- hide everything first, then show what this kind needs
		for _, w in ipairs(row.apiWidgets) do w:Hide() end
		row.boxA:Hide(); row.lblA:Hide(); row.capBtn:Hide()
		row.boxA:SetWidth(200)

		if kind == "cmd" then
			row.boxA:SetWidth(446)
			row.boxA:SetText(action.command or "")
			row.lblA:SetText("slash command  (Commands... inserts the highlighted one)")
			row.boxA:Show(); row.lblA:Show()
			row.Place(row.boxA, X_ADDON, 0)
			row.Place(row.lblA, X_ADDON, LABEL_DY)
		elseif kind == "api" then
			local prof = API.GetAddonProfiles(action.addon or "")
			row.addonBtn:SetText(action.addon ~= "" and action.addon or "<pick addon>")
			row.funcBtn:SetText(action.member ~= "" and action.member
				or (prof and "switch profile" or "<pick function>"))
			row.lblAddon:SetText(prof and ("addon (" .. prof.source .. ")") or "addon")
			row.lblFunc:SetText(prof and "function" or "function (no profile API)")
			row.addonBtn:Show(); row.lblAddon:Show()
			row.funcBtn:Show(); row.lblFunc:Show()

			local args = action.args
			-- Rows saved before the args list existed carried a single
			-- action.profile; fold it in so the box shows what will run.
			if type(args) ~= "table" or #args == 0 then
				local legacy = action.profile
				if (type(legacy) ~= "string" or legacy == "") and action.member ~= "" then
					legacy = nil  -- function takes no argument unless one is typed
				elseif type(legacy) ~= "string" or legacy == "" then
					legacy = "$profile"
				end
				args = legacy and { legacy } or {}
				action.args = args
			end
			local count = #args
			if action.member == "" and count == 0 then count = 1 end
			if type(action.paramNames) == "table" and #action.paramNames > count then
				count = #action.paramNames
			end
			if count > 4 then count = 4 end
			for i = 1, 4 do
				local box = row.argBoxes[i]
				local lbl = row.argLabels[i]
				if i <= count then
					box:SetText(tostring(args[i] or ""))
					box:Show()
					lbl:SetText(ArgLabel(action, i))
					lbl:Show()
				else
					box:Hide(); lbl:Hide()
				end
			end
			row.argPick:SetShown(count >= 1)
		else  -- snap
			row.boxA:SetWidth(200)
			row.boxA:SetText(action.savedvar or "")
			row.lblA:SetText("savedvar (CAP captures it)")
			row.boxA:Show(); row.lblA:Show()
			row.Place(row.boxA, X_ADDON, 0)
			row.Place(row.lblA, X_ADDON, LABEL_DY)
			row.capBtn:Show(); row.Place(row.capBtn, X_ADDON + 206, 0)
		end
	end

	local rows = {}

	local function BuildRow(index)
		local row = { apiWidgets = {}, argBoxes = {}, argLabels = {} }
		row.frame = CreateFrame("FRAME", nil, content)
		row.frame:SetSize(ROW_WIDTH, LABEL_DY + 12)
		local function Place(widget, dx, dy)
			widget:ClearAllPoints()
			widget:SetPoint("TOPLEFT", row.frame, "TOPLEFT", dx or 0, -(dy or 0))
		end
		row.Place = Place

		row.kindBtn = MakeButton(row.frame, nil, W_KIND, 20, "API")
		row.kindBtn:SetNormalFontObject("GameFontNormalSmall")
		row.kindBtn:SetScript("OnClick", function()
			local action = CurrentAction(row)
			if not action then return end
			-- cycle api -> cmd -> snap -> api; unrelated fields are kept so
			-- nothing typed is lost
			if action.kind == "api" or action.kind == nil then action.kind = "cmd"
			elseif action.kind == "cmd" then action.kind = "snap"
			else action.kind = "api" end
			RefreshRowVisuals(row, action)
		end)
		Place(row.kindBtn, X_KIND, 0)

		-- Shared text box: command (CMD) or savedvar (SNAP).
		row.boxA = MakeEditBox(row.frame, nil, 200)
		row.boxA:SetScript("OnEditFocusGained", function()
			Core.ui.lastCmdBox = row.boxA
		end)
		row.boxA:SetScript("OnTextChanged", function(self)
			local action = CurrentAction(row)
			if not action then return end
			if action.kind == "snap" then
				action.savedvar = (self:GetText() or ""):match("^%s*(.-)%s*$") or ""
			elseif action.kind ~= "api" then
				action.command = self:GetText() or ""
			end
		end)
		row.boxA:SetScript("OnEnter", function(self)
			local action = CurrentAction(row)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if action and action.kind == "snap" then
				GameTooltip:SetText("Saved-variable name", 1, 0.82, 0)
				GameTooltip:AddLine("The global table this addon stores settings in", 0.9, 0.9, 0.9)
				GameTooltip:AddLine("(## SavedVariables: line in its .toc).", 0.9, 0.9, 0.9)
				GameTooltip:AddLine("Type the name, then click CAP to capture", 0.9, 0.9, 0.9)
				GameTooltip:AddLine("current settings into this profile.", 0.9, 0.9, 0.9)
			else
				GameTooltip:SetText("Slash command to run", 1, 0.82, 0)
				GameTooltip:AddLine("Type '/details ...' etc. Type part of a word and", 0.9, 0.9, 0.9)
				GameTooltip:AddLine("press Commands... to see matching commands.", 0.9, 0.9, 0.9)
			end
			GameTooltip:Show()
		end)
		row.boxA:SetScript("OnLeave", function() GameTooltip:Hide() end)
		Place(row.boxA, X_ADDON, 0)

		row.lblA = MakeLabel(row.frame, "", "LEFT")
		row.lblA:SetTextColor(0.65, 0.65, 0.65)
		Place(row.lblA, X_ADDON, LABEL_DY)

		-- API: addon dropdown.
		row.addonBtn = MakeButton(row.frame, nil, W_ADDON, 20, "<pick addon>")
		row.addonBtn:SetNormalFontObject("GameFontNormalSmall")
		row.addonBtn:SetScript("OnClick", function()
			local action = CurrentAction(row)
			if not action then return end
			Core.ui.pickerAction = action
			addonPicker:Open("", row.addonBtn)
		end)
		row.addonBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Addon", 1, 0.82, 0)
			GameTooltip:AddLine("Pick the addon to configure. AceDB addons", 0.9, 0.9, 0.9)
			GameTooltip:AddLine("(Bartender4, Plater, Questie...) and Details are", 0.9, 0.9, 0.9)
			GameTooltip:AddLine("listed first, with their current profile.", 0.9, 0.9, 0.9)
			GameTooltip:Show()
		end)
		row.addonBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		Place(row.addonBtn, X_ADDON, 0)
		row.lblAddon = MakeLabel(row.frame, "", "LEFT")
		row.lblAddon:SetTextColor(0.65, 0.65, 0.65)
		Place(row.lblAddon, X_ADDON, LABEL_DY)
		row.apiWidgets[#row.apiWidgets + 1] = row.addonBtn
		row.apiWidgets[#row.apiWidgets + 1] = row.lblAddon

		-- API: function dropdown.
		row.funcBtn = MakeButton(row.frame, nil, W_FUNC, 20, "switch profile")
		row.funcBtn:SetNormalFontObject("GameFontNormalSmall")
		row.funcBtn:SetScript("OnClick", function()
			local action = CurrentAction(row)
			if not action then return end
			Core.ui.pickerAction = action
			funcPicker:Open("", row.funcBtn)
		end)
		row.funcBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Function to call", 1, 0.82, 0)
			GameTooltip:AddLine("'switch profile' uses the addon's own profile", 0.9, 0.9, 0.9)
			GameTooltip:AddLine("API. Type in the list to search every function", 0.9, 0.9, 0.9)
			GameTooltip:AddLine("the addon exposes.", 0.9, 0.9, 0.9)
			GameTooltip:Show()
		end)
		row.funcBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		Place(row.funcBtn, X_FUNC, 0)
		row.lblFunc = MakeLabel(row.frame, "", "LEFT")
		row.lblFunc:SetTextColor(0.65, 0.65, 0.65)
		Place(row.lblFunc, X_FUNC, LABEL_DY)
		row.apiWidgets[#row.apiWidgets + 1] = row.funcBtn
		row.apiWidgets[#row.apiWidgets + 1] = row.lblFunc

		-- API: argument boxes (1 always, 2-4 when the function needs them).
		local argX = { X_ARG1, X_ARG2, X_ARG3, X_ARG4 }
		local argW = { W_ARG1, W_ARG2, W_ARG3, W_ARG4 }
		for n = 1, 4 do
			local box = MakeEditBox(row.frame, nil, argW[n])
			box:SetScript("OnTextChanged", function(self)
				local action = CurrentAction(row)
				if not action or action.kind ~= "api" then return end
				action.args = action.args or {}
				action.args[n] = (self:GetText() or ""):match("^%s*(.-)%s*$") or ""
			end)
			box:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText("Argument " .. n, 1, 0.82, 0)
				GameTooltip:AddLine("Passed to the function. '$profile' means the", 0.9, 0.9, 0.9)
				GameTooltip:AddLine("Chungus profile being applied, so a row with", 0.9, 0.9, 0.9)
				GameTooltip:AddLine("'$profile' switches each addon to the profile", 0.9, 0.9, 0.9)
				GameTooltip:AddLine("of the same name.", 0.9, 0.9, 0.9)
				GameTooltip:Show()
			end)
			box:SetScript("OnLeave", function() GameTooltip:Hide() end)
			Place(box, argX[n], 0)
			row.argBoxes[n] = box
			local lbl = MakeLabel(row.frame, "", "LEFT")
			lbl:SetTextColor(0.65, 0.65, 0.65)
			Place(lbl, argX[n], LABEL_DY)
			row.argLabels[n] = lbl
			row.apiWidgets[#row.apiWidgets + 1] = box
			row.apiWidgets[#row.apiWidgets + 1] = lbl
		end

		-- Profile picker beside argument 1: lists that addon's real profiles.
		row.argPick = MakeButton(row.frame, nil, W_ARG1DD, 20, "v")
		row.argPick:SetNormalFontObject("GameFontNormalSmall")
		row.argPick:SetScript("OnClick", function()
			local action = CurrentAction(row)
			if not action then return end
			Core.ui.pickerAction = action
			profilePicker:Open("", row.argPick)
		end)
		row.argPick:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Pick a profile", 1, 0.82, 0)
			GameTooltip:AddLine("Lists the profiles that exist in the chosen addon.", 0.9, 0.9, 0.9)
			GameTooltip:AddLine("$profile = same name as this Chungus profile.", 0.9, 0.9, 0.9)
			GameTooltip:Show()
		end)
		row.argPick:SetScript("OnLeave", function() GameTooltip:Hide() end)
		Place(row.argPick, X_ARG1DD, 0)
		row.apiWidgets[#row.apiWidgets + 1] = row.argPick

		-- Extra argument box (for functions whose arity is not detectable,
		-- e.g. C functions, or when passing more than the declared params).
		row.plusBtn = MakeButton(row.frame, nil, W_PLUS, 20, "+")
		row.plusBtn:SetNormalFontObject("GameFontNormalSmall")
		row.plusBtn:SetScript("OnClick", function()
			local action = CurrentAction(row)
			if not action then return end
			action.args = action.args or {}
			if #action.args < 4 then
				action.args[#action.args + 1] = ""
				RefreshRowVisuals(row, action)
			end
		end)
		row.plusBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Add another argument", 1, 0.82, 0)
			GameTooltip:AddLine("Arguments are detected from the function signature;", 0.9, 0.9, 0.9)
			GameTooltip:AddLine("use this for functions that take more (or whose", 0.9, 0.9, 0.9)
			GameTooltip:AddLine("signature cannot be read).", 0.9, 0.9, 0.9)
			GameTooltip:Show()
		end)
		row.plusBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		Place(row.plusBtn, X_PLUS, 0)
		row.apiWidgets[#row.apiWidgets + 1] = row.plusBtn

		row.capBtn = MakeButton(row.frame, nil, 36, 20, "CAP")
		row.capBtn:SetNormalFontObject("GameFontNormalSmall")
		row.capBtn:SetScript("OnClick", function()
			local action = CurrentAction(row)
			if action and action.kind == "snap" and (action.savedvar or "") ~= "" then
				API.CaptureSnapshot(Core.ui.selected, action.savedvar)
			end
		end)
		Place(row.capBtn, X_ADDON + 206, 0)

		-- Run: execute just this action immediately (test button; does not
		-- change the applied profile).
		row.runBtn = MakeButton(row.frame, nil, 28, 20, "Run")
		row.runBtn:SetNormalFontObject("GameFontNormalSmall")
		row.runBtn:SetScript("OnClick", function()
			local profileName = Core.ui.selected
			if not profileName or not API.GetProfile(profileName) then return end
			local action = CurrentAction(row)
			if action then
				if API.RegisterAceHandlers then API.RegisterAceHandlers() end
				API.RunAction(profileName, action)
			end
		end)
		Place(row.runBtn, X_RUN, 0)

		row.delBtn = MakeButton(row.frame, nil, 22, 20, "x")
		row.delBtn:SetNormalFontObject("GameFontNormalSmall")
		row.delBtn:SetScript("OnClick", function()
			local profileName = Core.ui.selected
			if not profileName or not row.index then return end
			local profile = API.GetProfile(profileName)
			if not profile then return end
			table.remove(GetData(profile).actions, row.index)
			Core.RefreshUI()
		end)
		Place(row.delBtn, X_DEL, 0)

		return row
	end

	local function GetRow(index)
		if not rows[index] then rows[index] = BuildRow(index) end
		return rows[index]
	end

	local addActionBtn = MakeButton(page, nil, 74, 20, "+ Action")
	addActionBtn:SetScript("OnClick", function()
		local profile = API.GetProfile(Core.ui.selected)
		if not profile then return end
		-- API rows are the common case (switch an addon's profile on apply).
		tinsert(GetData(profile).actions, { kind = "api", addon = "", member = "", args = { "$profile" } })
		Core.RefreshUI()
		SetScroll(MaxScroll())
	end)

	local runAllBtn = MakeButton(page, nil, 64, 20, "Run All")
	runAllBtn:SetScript("OnClick", function()
		local profileName = Core.ui.selected
		if not profileName or not API.GetProfile(profileName) then
			print("[Chungus Setup] No profile selected.")
			return
		end
		OnApply(profileName)
	end)
	runAllBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Run every action now, staggered", 1, 0.82, 0)
		GameTooltip:AddLine("Same as applying this profile's Setup actions,", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("but does not change the applied profile.", 0.9, 0.9, 0.9)
		GameTooltip:Show()
	end)
	runAllBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local note = MakeLabel(page,
		"API = switch another addon's profile on apply. Rows keep the same order at login.")
	note:SetTextColor(0.65, 0.65, 0.65)

	TrackFont(editingLabel)
	TrackFont(note)
	TrackFont(addActionBtn, true)
	TrackFont(runAllBtn, true)
	TrackFont(commandsBtn, true)

	-- Header stays pinned; the rows scroll. Re-run whenever Options changes
	-- padding, spacing or font size.
	local function ApplyLayout()
		local ui = API.GetUISettings()
		local pad = ui.padding
		local rowHeight = LABEL_DY + ui.fontSize
		local step = rowHeight + ui.rowGap

		editingLabel:ClearAllPoints()
		editingLabel:SetPoint("TOPLEFT", page, "TOPLEFT", pad, -3)

		commandsBtn:ClearAllPoints()
		commandsBtn:SetPoint("TOPRIGHT", page, "TOPRIGHT", -pad, -3)
		runAllBtn:ClearAllPoints()
		runAllBtn:SetPoint("TOPRIGHT", commandsBtn, "TOPLEFT", -6, 0)
		addActionBtn:ClearAllPoints()
		addActionBtn:SetPoint("TOPRIGHT", runAllBtn, "TOPLEFT", -6, 0)

		scroll:ClearAllPoints()
		scroll:SetPoint("TOPLEFT", page, "TOPLEFT", pad, -(26 + pad))
		scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -(pad + 4), 16 + pad)

		note:ClearAllPoints()
		note:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", pad, pad)

		for i = 1, #rows do
			local row = rows[i]
			row.frame:SetHeight(rowHeight)
			row.frame:ClearAllPoints()
			row.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * step))
		end
		ApplyFonts()
		UpdateContent()
	end
	page.layout = ApplyLayout

	local function HideRow(row)
		row.index = nil
		if row.frame then row.frame:Hide() end
		row.kindBtn:Hide(); row.boxA:Hide(); row.lblA:Hide()
		row.capBtn:Hide(); row.runBtn:Hide(); row.delBtn:Hide()
		for _, w in ipairs(row.apiWidgets) do w:Hide() end
		for n = 1, 4 do
			row.argBoxes[n]:Hide()
			row.argLabels[n]:Hide()
		end
	end

	page.render = function()
		local selected = Core.ui.selected
		local profile = selected and API.GetProfile(selected) or nil
		if not profile then
			editingLabel:SetText("No profile selected - pick one in the Profiles tab")
			for i = 1, #rows do HideRow(rows[i]) end
			visibleRows = 0
			addActionBtn:Disable()
			runAllBtn:Disable()
			ApplyLayout()
			return
		end
		addActionBtn:Enable()
		runAllBtn:Enable()
		local actions = GetData(profile).actions
		local count = #actions
		if count > MAX_ROWS then count = MAX_ROWS end
		editingLabel:SetText("Editing profile: " .. selected .. "  (" .. #actions .. " actions)")
		for i = 1, count do
			local row = GetRow(i)
			row.index = i
			RefreshRowVisuals(row, actions[i])
			row.frame:Show()
			row.kindBtn:Show(); row.runBtn:Show(); row.delBtn:Show()
		end
		for i = count + 1, #rows do HideRow(rows[i]) end
		visibleRows = count
		ApplyLayout()
	end
end, OnApply)

print("[Chungus Setup] Module loaded - 'Setup' tab registered with Chungus.")
