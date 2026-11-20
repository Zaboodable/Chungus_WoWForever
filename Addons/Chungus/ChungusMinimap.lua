-- Chungus (minimap button) — draggable orbit icon with a left-click dropdown
-- menu (open tabs, quick-load from defaults, confirm-armed char reset) and
-- right-click to open the window. Visibility is toggled by the "Minimap
-- button" checkbox in the Profiles tab (ChungusDB.settings.showMinimap).
--
-- Same orbit pattern TaurenRegret proved on this client: drag recomputes the
-- angle from the cursor relative to the minimap center; the angle persists.

local AddonName, Addon = ...

local Chungus = _G.Chungus
local Core = Chungus.Core
local API = Chungus.API

-- ------------------------------------------------------------------
-- The button.
-- ------------------------------------------------------------------
local minimap_button = CreateFrame("BUTTON", "_ChungusMinimapButton", Minimap)
minimap_button:SetFrameStrata("MEDIUM")
minimap_button:SetSize(32, 32)
minimap_button:SetFrameLevel(8)
minimap_button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimap_button:RegisterForDrag("LeftButton")

minimap_button.icon = minimap_button:CreateTexture(nil, "BACKGROUND")
minimap_button.icon:SetSize(20, 20)
minimap_button.icon:SetPoint("CENTER")
minimap_button.icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
minimap_button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- crop the icon square
minimap_button.border = minimap_button:CreateTexture(nil, "OVERLAY")
minimap_button.border:SetSize(54, 54)
minimap_button.border:SetPoint("TOPLEFT")
minimap_button.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function UpdatePos()
	local angle = API.GetSettings().minimapAngle or -math.pi / 4
	local radius = (Minimap:GetWidth() / 2) + 8
	minimap_button:ClearAllPoints()
	minimap_button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- Dragging orbits the button around the minimap; the angle persists.
minimap_button.dragging = false
minimap_button:SetScript("OnDragStart", function(self) self.dragging = true end)
minimap_button:SetScript("OnDragStop", function(self) self.dragging = false end)
minimap_button:SetScript("OnUpdate", function(self, elapsed)
	if self.dragging then
		local mx, my = Minimap:GetCenter()
		local px, py = GetCursorPosition()
		local scale = Minimap:GetEffectiveScale()
		px, py = px / scale, py / scale
		API.GetSettings().minimapAngle = math.atan2(py - my, px - mx)
		UpdatePos()
	end
end)

-- Hover tooltip: current profile state at a glance.
minimap_button:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
	GameTooltip:SetText("Chungus", 1, 0.82, 0)
	local resolved, via = API.GetResolvedProfile()
	local db = API.EnsureDB()
	GameTooltip:AddDoubleLine("Applied:", ChungusCharDB.applied or "-", 1, 1, 1, 1, 0.9, 0.85)
	GameTooltip:AddDoubleLine("Auto:", resolved and (resolved .. " (" .. via .. ")") or "-", 1, 1, 1, 0.9, 0.85)
	GameTooltip:AddDoubleLine("Role:", ChungusCharDB.role or "none", 1, 1, 1, 0.9, 0.85)
	GameTooltip:AddDoubleLine("Global:", db.globalDefault or "-", 1, 1, 1, 0.9, 0.85)
	GameTooltip:AddLine("Left click: menu", 0.7, 0.7, 0.7)
	GameTooltip:AddLine("Right click: open window", 0.7, 0.7, 0.7)
	GameTooltip:AddLine("Drag: move around minimap", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end)
minimap_button:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ------------------------------------------------------------------
-- Left-click dropdown menu. If the dropdown API misbehaves on this client,
-- fall back to just opening the window (never leave the user with nothing).
-- ------------------------------------------------------------------
local menuFrame = CreateFrame("FRAME", "_ChungusMinimapMenu", UIParent, "UIDropDownMenuTemplate")

local function AddItem(level, info)
	info.notCheckable = true
	UIDropDownMenu_AddButton(info, level)
end

local ROLE_ITEMS = {
	{ key = "tank",   label = "tank" },
	{ key = "healer", label = "heal" },
	{ key = "dps",    label = "dps" },
}

local function BuildMenu(self, level)
	if level ~= 1 then return end

	AddItem(1, { text = "Profiles", func = function()
		Core.ui.activeTab = "profiles"
		Core.ToggleWindow()
	end })
	AddItem(1, { text = "Setup", func = function()
		Core.ui.activeTab = "setup"
		Core.ToggleWindow()
	end })

	pcall(UIDropDownMenu_AddSeparator, level)

	AddItem(1, { text = "load", isTitle = true })

	local db = API.EnsureDB()
	local gName = db.globalDefault
	AddItem(1, {
		text = "Global default: " .. (gName or "none"),
		disabled = not gName,
		func = function() API.ApplyProfile(gName) end,
		tooltipOnButton = not gName,
		tooltipTitle = "No global default set",
		tooltipText = "Select a profile in the window, then press Set as default: Global.",
	})
	for _, role in ipairs(ROLE_ITEMS) do
		local pName = db.roleDefaults[role.key]
		AddItem(1, {
			text = "Role: " .. role.label .. (pName and (" - " .. pName) or " (unset)"),
			disabled = not pName,
			func = function() API.ApplyProfile(pName) end,
			tooltipOnButton = not pName,
			tooltipTitle = "No " .. role.label .. " default set",
			tooltipText = "Set a role in the window, then press Set as default: Role.",
		})
	end

	pcall(UIDropDownMenu_AddSeparator, level)

	-- Confirm-armed reset (the menu closes on click, so confirmation happens
	-- on the NEXT menu open within 10 seconds).
	local armed = menuFrame.resetArmed and GetTime() - (menuFrame.resetArmedAt or 0) <= 10
	AddItem(1, {
		text = armed and "Reset char - click again to confirm" or "Reset char",
		func = function()
			if armed then
				ChungusCharDB.applied = nil
				ChungusCharDB.role = nil
				menuFrame.resetArmed = nil
				print("[Chungus] This character's applied profile and role were reset.")
				Core.RefreshUI()
			else
				menuFrame.resetArmed = true
				menuFrame.resetArmedAt = GetTime()
				print("[Chungus] Open the menu again and click 'Reset char' to confirm.")
			end
		end,
	})
end

local okInitMenu = pcall(UIDropDownMenu_Initialize, menuFrame, BuildMenu, "MENU")

minimap_button:SetScript("OnClick", function(self, mouse)
	if mouse == "RightButton" then
		Core.ToggleWindow()
		return
	end
	if not okInitMenu or not ToggleDropDownMenu then
		Core.ToggleWindow()
		return
	end
	local ok = pcall(ToggleDropDownMenu, 1, nil, menuFrame, "cursor")
	if not ok then
		print("[Chungus] Minimap menu failed on this client - opening the window instead.")
		Core.ToggleWindow()
	end
end)

-- ------------------------------------------------------------------
-- Visibility. Saved variables land after files run, so re-apply at
-- PLAYER_ENTERING_WORLD; the Profiles-tab checkbox calls
-- Core.UpdateMinimapVisibility() immediately.
-- ------------------------------------------------------------------
local function ApplyVisibility()
	local s = API.GetSettings()
	if s.showMinimap == false then
		minimap_button:Hide()
	else
		minimap_button:Show()
		UpdatePos()
	end
end

function Core.UpdateMinimapVisibility()
	ApplyVisibility()
end

minimap_button:RegisterEvent("PLAYER_ENTERING_WORLD")
minimap_button:SetScript("OnEvent", function() ApplyVisibility() end)
ApplyVisibility()

print("[Chungus] Minimap button ready - left click: menu, right click: window.")
