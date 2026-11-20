-- Chungus Chat (placeholder module of Chungus) — the "Chat" tab.
--
-- Deliberately minimal: exists to prove the module system works end to end.
-- It registers a tab (page content + apply behavior) and is included/excluded
-- per profile via the checkbox in the Profiles tab. Applying a profile with
-- this module checked prints a line so you can watch the dispatch order.
--
-- NOTE: the second vararg of an addon file is PER-ADDON. This child module
-- reaches the core's shared table through Chungus.Core, never through its own
-- local Addon.

local AddonName, Addon = ...

local Chungus = _G.Chungus
local Core = Chungus.Core
local API = Chungus.API
local MakeLabel = Core.MakeLabel

local function OnApply(profileName)
	print("[Chungus Chat] Placeholder apply ran for profile '" .. tostring(profileName) .. "'.")
end

API.RegisterTab("chat", "Chat", "ChungusChat", function(page)
	local header = MakeLabel(page, "Chungus Chat - placeholder")
	header:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -2)

	local body = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	body:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -20)
	body:SetJustifyH("LEFT")
	body:SetSpacing(2)
	body:SetText("Future chat features will live in this module.\n\n"
		.. "This tab proves the module system: it is registered like any other\n"
		.. "module, and the Profiles tab has a per-profile checkbox for it.\n"
		.. "Enable 'Chat' in a profile, apply it, and you will see its apply\n"
		.. "print in the chat frame.")

	-- Optional: a simple flag so future chat settings have a place to live.
	page.render = function() end
end, OnApply)

print("[Chungus Chat] Module loaded - 'Chat' tab registered with Chungus.")
