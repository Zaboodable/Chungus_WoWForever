-- Chungus (Profiles tab) — profile list, create/rename/delete, defaults
-- (global / class / role), per-module include flags, apply buttons, status.
--
-- The ACTIONS of a profile live in the modules' own tabs (e.g. the "Setup"
-- tab of ChungusSetup edits profile.moduleData.ChungusSetup.actions).
-- This tab is the manager: what profiles exist, which modules they include,
-- and what gets applied for this character.
--
-- Layout uses the column kit (Addon.NewColumn): widgets stack automatically,
-- so rows can't overwrite each other.

local AddonName, Addon = ...

local Chungus = _G.Chungus
local API = Chungus.API
local MakeButton = Addon.MakeButton
local MakeEditBox = Addon.MakeEditBox
local MakeLabel = Addon.MakeLabel
local NewColumn = Addon.NewColumn

local function DB()
	return API.EnsureDB()
end

local function Trim(s)
	return type(s) == "string" and string.trim(s) or ""
end

API.RegisterTab("profiles", "Profiles", "Chungus", function(page)

	-- ------------------------------------------------------------------
	-- Left column: profile list + creation.
	-- ------------------------------------------------------------------
	local left = NewColumn(page, 0)

	local listHeader = MakeLabel(page, "Profiles")
	left:Add(listHeader, 14, 10)

	local PROFILE_ROWS = 10
	local profileRows = {}
	for i = 1, PROFILE_ROWS do
		local btn = MakeButton(page, nil, 160, 20, "")
		btn:SetNormalFontObject("GameFontHighlightSmall")
		btn:SetScript("OnClick", function(self)
			if self.profileName then
				Addon.ui.selected = self.profileName
				Addon.RefreshUI()
			end
		end)
		btn:SetScript("OnEnter", function(self)
			local name = self.profileName
			if not name then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(name, 1, 0.82, 0)
			local profile = API.GetProfile(name)
			if profile then
				if profile.onLogin then GameTooltip:AddLine("Runs at login", 0.9, 0.9, 0.9) end
				local mods = {}
				for key, on in pairs(profile.modules or {}) do
					if on then tinsert(mods, key) end
				end
				if #mods > 0 then
					GameTooltip:AddLine("Modules: " .. table.concat(mods, ", "), 0.9, 0.9, 0.9)
				end
				if profile.snapshots then
					for sv in pairs(profile.snapshots) do
						GameTooltip:AddLine("snapshot: " .. sv, 0.7, 0.7, 0.9)
					end
				end
			end
			local db = DB()
			if db.globalDefault == name then GameTooltip:AddLine("Global default", 1, 0.82, 0) end
			if API.GetDefaultTier("class") == name then GameTooltip:AddLine("Class default", 1, 0.82, 0) end
			if API.GetDefaultTier("role") == name then GameTooltip:AddLine("Role default", 1, 0.82, 0) end
			if ChungusCharDB.applied == name then GameTooltip:AddLine("Applied for this character", 0.4, 1, 0.4) end
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		left:Add(btn, 20, 2)
		profileRows[i] = btn
	end

	-- new profile row: editbox + New button side by side
	local newRowY = left:Reserve(24, 12)
	local newProfileBox = MakeEditBox(page, "_ChungusNewBox", 110)
	newProfileBox:SetScript("OnEnterPressed", function(self)
		local name = Trim(self:GetText())
		if name ~= "" then
			local _, status = API.CreateProfile(name)
			if status == "created" or status == "exists" then
				Addon.ui.selected = name
				self:SetText("")
				self:ClearFocus()
			end
			Addon.RefreshUI()
		end
	end)
	left:Place(newProfileBox, 4, newRowY)
	local newProfileBtn = MakeButton(page, nil, 46, 22, "New")
	newProfileBtn:SetScript("OnClick", function()
		newProfileBox:GetScript("OnEnterPressed")(newProfileBox)
	end)
	left:Place(newProfileBtn, 122, newRowY)

	local listNote = MakeLabel(page, "Type a name, press New (Enter)", "LEFT")
	left:Add(listNote, 12, 8)

	-- ------------------------------------------------------------------
	-- Right column: selected profile editor.
	-- ------------------------------------------------------------------
	local right = NewColumn(page, 196)

	local row1Y = right:Reserve(24, 10)
	local nameLabel = MakeLabel(page, "Name:")
	right:Place(nameLabel, 0, row1Y)
	local nameBox = MakeEditBox(page, "_ChungusNameBox", 120)
	nameBox:SetScript("OnEnterPressed", function(self)
		local old = Addon.ui.selected
		local newName = Trim(self:GetText())
		if old and newName ~= "" then
			API.RenameProfile(old, newName)
			Addon.ui.selected = newName
		end
		self:ClearFocus()
		Addon.RefreshUI()
	end)
	right:Place(nameBox, 42, row1Y)

	-- Confirm-armed delete: first click arms, second click within 3s deletes.
	local deleteBtn = MakeButton(page, nil, 56, 22, "Delete")
	deleteBtn:SetScript("OnClick", function(self)
		local name = Addon.ui.selected
		if not name then return end
		if not self.armed or self.armed ~= name or GetTime() - (self.armedAt or 0) > 3 then
			self.armed = name
			self.armedAt = GetTime()
			self:SetText("Sure?")
			return
		end
		self.armed = nil
		self:SetText("Delete")
		API.DeleteProfile(name)
		Addon.ui.selected = nil
		Addon.RefreshUI()
	end)
	right:Place(deleteBtn, 174, row1Y)

	local row2Y = right:Reserve(22, 12)
	local defLabel = MakeLabel(page, "Set as default:")
	right:Place(defLabel, 0, row2Y)
	for i, def in ipairs({ { "Global", "global" }, { "Class", "class" }, { "Role", "role" } }) do
		local btn = MakeButton(page, nil, 54, 20, def[1])
		btn:SetNormalFontObject("GameFontNormalSmall")
		btn:SetScript("OnClick", function()
			if Addon.ui.selected then
				API.SetDefaultTier(def[2], Addon.ui.selected)
				Addon.RefreshUI()
			end
		end)
		right:Place(btn, 88 + (i - 1) * 60, row2Y)
	end

	local onLoginCheck = CreateFrame("CHECKBUTTON", "_ChungusOnLoginCheck", page, "UICheckButtonTemplate")
	onLoginCheck:SetSize(18, 18)
	_G["_ChungusOnLoginCheckText"]:SetText("Run actions at login")
	_G["_ChungusOnLoginCheckText"]:SetFontObject("GameFontHighlightSmall")
	_G["_ChungusOnLoginCheckText"]:SetPoint("LEFT", onLoginCheck, "RIGHT", 0, 0)
	onLoginCheck:SetScript("OnClick", function(self)
		local profile = API.GetProfile(Addon.ui.selected)
		if profile then
			profile.onLogin = self:GetChecked() and true or false
		end
	end)
	right:Add(onLoginCheck, 18, 14)

	local modsLabel = MakeLabel(page, "Modules included in this profile:")
	right:Add(modsLabel, 12, 4)

	-- ------------------------------------------------------------------
	-- Module include flags: one checkbox per registered module (the Profiles
	-- tab itself has nothing to apply, so it is not listed).
	-- ------------------------------------------------------------------
	local MOD_CHECKS = 6
	local modChecks = {}
	local modTexts = {}
	for i = 1, MOD_CHECKS do
		local cb = CreateFrame("CHECKBUTTON", "_ChungusModCheck" .. i, page, "UICheckButtonTemplate")
		cb:SetSize(18, 18)
		local tf = _G["_ChungusModCheck" .. i .. "Text"]
		if tf then
			tf:SetFontObject("GameFontHighlightSmall")
			tf:SetPoint("LEFT", cb, "RIGHT", 0, 0)
			modTexts[i] = tf
		end
		cb:SetScript("OnClick", function(self)
			local profile = API.GetProfile(Addon.ui.selected)
			if self.modKey and profile then
				profile.modules[self.modKey] = self:GetChecked() and true or false
			end
		end)
		right:Add(cb, 18, 2)
		modChecks[i] = cb
	end

	-- Minimap button visibility (shared with ChungusMinimap.lua).
	local minimapCheck = CreateFrame("CHECKBUTTON", "_ChungusMinimapCheck", page, "UICheckButtonTemplate")
	minimapCheck:SetSize(18, 18)
	local mtf = _G["_ChungusMinimapCheckText"]
	if mtf then
		mtf:SetFontObject("GameFontHighlightSmall")
		mtf:SetPoint("LEFT", minimapCheck, "RIGHT", 0, 0)
		mtf:SetText("Minimap button")
	end
	minimapCheck:SetScript("OnClick", function(self)
		local s = API.GetSettings()
		s.showMinimap = self:GetChecked() and true or false
		if Addon.UpdateMinimapVisibility then Addon.UpdateMinimapVisibility() end
	end)
	right:Add(minimapCheck, 18, 10)

	-- ------------------------------------------------------------------
	-- Bottom bar (anchored to the page bottom, shared across both columns).
	-- ------------------------------------------------------------------
	local applyHint = MakeLabel(page,
		"Auto = applied > class > role > global. Edit this profile's addon actions in the Setup tab.", "LEFT")
	applyHint:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 50)

	local statusText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statusText:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 28)
	statusText:SetJustifyH("LEFT")

	local roleBtn = MakeButton(page, "_ChungusRoleBtn", 110, 22, "Role: none")
	roleBtn:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	roleBtn:SetScript("OnClick", function()
		local current = ChungusCharDB.role or "none"
		local nextIdx = 2
		for i, r in ipairs(API.ROLES) do
			if r == current then nextIdx = (i % #API.ROLES) + 1 end
		end
		local nextRole = API.ROLES[nextIdx]
		ChungusCharDB.role = (nextRole ~= "none") and nextRole or nil
		Addon.RefreshUI()
	end)
	roleBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Role for this character", 1, 0.82, 0)
		GameTooltip:AddLine("Used by the role default when resolving Auto.", 0.9, 0.9, 0.9)
		GameTooltip:Show()
	end)
	roleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local function MakeApplyButton(label, tier, xoff)
		local btn = MakeButton(page, nil, 62, 22, label)
		btn:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 118 + xoff, 0)
		btn:SetScript("OnClick", function()
			local name = tier and API.GetDefaultTier(tier) or nil
			if tier and not name then
				print("[Chungus] No " .. tier .. " default set (select a profile, then press its Set-as-default button).")
				return
			end
			API.ApplyProfile(name)
		end)
		return btn
	end
	MakeApplyButton("Auto", nil, 0)
	MakeApplyButton("Global", "global", 64)
	MakeApplyButton("Class", "class", 128)
	MakeApplyButton("Role", "role", 192)

	local clearBtn = MakeButton(page, nil, 62, 22, "Clear")
	clearBtn:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 118 + 256, 0)
	clearBtn:SetScript("OnClick", function() API.ClearApplied() end)

	-- Confirm-armed reset of THIS character only: applied profile + role back to
	-- unset, so Auto falls through to class/role/global defaults again. Global
	-- profiles and defaults are untouched.
	local resetBtn = MakeButton(page, nil, 74, 22, "Reset Char")
	resetBtn:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 118 + 320, 0)
	resetBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Reset this character", 1, 0.82, 0)
		GameTooltip:AddLine("Clears the applied profile and the role for this", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("character only. Profiles and global defaults stay.", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("Auto then resolves from class > role > global.", 0.9, 0.9, 0.9)
		GameTooltip:Show()
	end)
	resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	resetBtn:SetScript("OnClick", function(self)
		if not self.armed or GetTime() - (self.armedAt or 0) > 3 then
			self.armed = true
			self.armedAt = GetTime()
			self:SetText("Sure?")
			return
		end
		self.armed = nil
		self:SetText("Reset Char")
		ChungusCharDB.applied = nil
		ChungusCharDB.role = nil
		print("[Chungus] This character's applied profile and role were reset.")
		Addon.RefreshUI()
	end)

	-- ------------------------------------------------------------------
	-- Rendering.
	-- ------------------------------------------------------------------
	local function RenderProfileList()
		local db = DB()
		local names = API.GetProfiles()
		for i = 1, PROFILE_ROWS do
			local btn = profileRows[i]
			if names[i] then
				btn.profileName = names[i]
				local label = names[i]
				if db.globalDefault == names[i] then label = label .. " |cffffd100G|r" end
				if API.GetDefaultTier("class") == names[i] then label = label .. " |cff8ff0ffC|r" end
				if API.GetDefaultTier("role") == names[i] then label = label .. " |cffaaffaaR|r" end
				if ChungusCharDB.applied == names[i] then label = label .. " |cff55ff55*" end
				btn:SetText(label)
				btn:Show()
			else
				btn.profileName = nil
				btn:SetText("")
				btn:Hide()
			end
		end
		if #names > PROFILE_ROWS then
			listNote:SetText("Showing first " .. PROFILE_ROWS .. " of " .. #names)
		else
			listNote:SetText("Type a name, press New (Enter)")
		end
	end

	local function RenderEditor()
		local db = DB()
		local selected = Addon.ui.selected
		local profile = selected and db.profiles[selected] or nil

		-- if nothing is selected yet, pick the first profile
		if not profile and not selected then
			local names = API.GetProfiles()
			if names[1] then
				selected = names[1]
				Addon.ui.selected = selected
				profile = db.profiles[selected]
			end
		end

		nameBox:SetText(profile and selected or "")
		-- Enable/Disable instead of SetEnabled: present on every client generation.
		if profile then nameBox:Enable() else nameBox:Disable() end
		if profile then deleteBtn:Enable() else deleteBtn:Disable() end

		if profile then
			onLoginCheck:Enable()
			onLoginCheck:SetChecked(profile.onLogin)
		else
			onLoginCheck:Disable()
			onLoginCheck:SetChecked(false)
		end

		-- module checkboxes
		local idx = 0
		for _, tab in ipairs(Addon.Tabs) do
			if tab.key ~= "profiles" and idx < MOD_CHECKS then
				idx = idx + 1
				modChecks[idx].modKey = tab.key
				modChecks[idx]:Show()
				if modTexts[idx] then modTexts[idx]:SetText(tab.title) end
				if profile then
					modChecks[idx]:Enable()
					if profile.modules[tab.key] == nil then profile.modules[tab.key] = true end
					modChecks[idx]:SetChecked(profile.modules[tab.key])
				else
					modChecks[idx]:Disable()
					modChecks[idx]:SetChecked(false)
				end
			end
		end
		for i = idx + 1, MOD_CHECKS do
			modChecks[i].modKey = nil
			modChecks[i]:Hide()
		end

		if minimapCheck then
			minimapCheck:SetChecked(API.GetSettings().showMinimap ~= false)
		end
	end

	local function RenderStatus()
		local db = DB()
		local resolved, via = API.GetResolvedProfile()
		local role = ChungusCharDB.role or "none"
		statusText:SetText(("role: %s   applied: %s   auto: %s   global: %s"):format(
			role,
			ChungusCharDB.applied or "-",
			resolved and (resolved .. " (" .. via .. ")") or "-",
			db.globalDefault or "-"))
		roleBtn:SetText("Role: " .. role)
	end

	page.render = function()
		RenderProfileList()
		RenderEditor()
		RenderStatus()
	end
end)
