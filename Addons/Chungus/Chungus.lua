-- Chungus (core) — profile manager platform shared by all Chungus* modules.
--
-- MODULES: every Chungus* child addon registers a TAB with
--   Chungus.API.RegisterTab(key, title, addonName, createPageFn, onApplyFn)
-- The core window shows one tab per registered module, plus grayed placeholder
-- tabs for installed-but-unloaded Chungus* addons. A profile has a bool per
-- module (profile.modules[key]); applying a profile only calls onApply of the
-- modules that are checked (nil defaults to ON for registered modules).
--
-- Applying OTHER addons' settings happens inside the Setup module (child addon
-- "ChungusSetup"), which stores its actions per profile in
-- profile.moduleData.ChungusSetup.actions. Three tiers of application:
--   1. "api"  — call the addon's own profile API via a handler registered with
--               Chungus.API.RegisterHandler(addonName, fn). Silent, instant, best.
--               AceDB-3.0 addons (Bartender4, Plater, Questie, HandyNotes,
--               Mapster, Decursive, RatingBuster, Spoken, AtlasLoot...) get a
--               handler automatically: db:SetProfile(name) via db_registry.
--   2. "cmd"  — run a slash command (e.g. "/details profile set PvP") through the
--               chat editbox. Works for anything with a profile command.
--   3. "snap" — restore a deep-copy snapshot of the addon's saved-variable table
--               (captured with CaptureSnapshot). Needs /reload to fully apply.
--               Universal fallback: an addon's settings are just a global table.
--
-- Data model:
--   ChungusDB (global, shared by all characters):
--     profiles[name] = { onLogin = bool,
--                        modules = { [moduleKey] = bool },
--                        moduleData = { ChungusSetup = { actions = { action, ... } } },
--                        snapshots = { [savedvarName] = deepCopy } }
--       action = { kind="cmd",  command="/addon profile set X" }
--              | { kind="api",  addon="Details", member="", args={ "$profile" } }
--              | { kind="snap", savedvar="SomeVar" }
--     settings = { ui = { padding, rowGap, fontSize, windowWidth, windowHeight } }
--       account-wide layout preferences (the window's Options tab)
--     globalDefault     = "name" | nil
--     classDefaults[file] = "name"    e.g. classDefaults.PRIEST = "Healer"
--     roleDefaults[role]  = "name"    role: "tank" | "healer" | "dps"
--   ChungusCharDB (per character):
--     applied = "name" | nil   -- explicitly applied profile for this character
--     role    = "tank"|"healer"|"dps" | nil  -- manual role for quick swap
--
-- Resolution order (what "Auto" means): per-char applied -> class default ->
-- role default -> global default.
--
-- NOTHING runs automatically until a profile is applied. At login the resolved
-- profile runs once, and only the modules checked in that profile.
--
-- Child addons load after this one via "## Dependencies: Chungus" and use:
--   local Chungus = _G.Chungus; Chungus.API.*

local AddonName, Addon = ...

local G = _G

-- Global namespace shared with every Chungus* child addon.
if not G.Chungus then G.Chungus = {} end
local Chungus = G.Chungus
Chungus.API = Chungus.API or {}
local API = Chungus.API

-- IMPORTANT: the second vararg of a file ("local AddonName, Addon = ...") is
-- PER-ADDON. Child modules get their own table, NOT this one. Anything that
-- must be shared across addons hangs off the global: Chungus.API (functions)
-- and Chungus.Core (this addon's shared state: ui, tabs, queue, widgets).
Chungus.Core = Addon

-- Shared UI state: selected profile, active tab, focused command box.
Addon.ui = { activeTab = "profiles", selected = nil, lastCmdBox = nil }

-- Registered tabs (ordered). Modules register during their file load; the
-- window (ChungusWindow.lua) renders the bar from this list.
Addon.Tabs = {}

function API.RegisterTab(key, title, addonName, createPage, onApply)
	if type(key) ~= "string" then return end
	for _, tab in ipairs(Addon.Tabs) do
		if tab.key == key then
			-- re-register (module file reloading): refresh in place
			tab.title = title or tab.title
			tab.addonName = addonName or tab.addonName
			tab.module = { key = key, createPage = createPage, onApply = onApply }
			if Addon.RefreshUI then Addon.RefreshUI() end
			return
		end
	end
	tinsert(Addon.Tabs, {
		key = key,
		title = title or key,
		addonName = addonName or key,
		module = { key = key, createPage = createPage, onApply = onApply },
	})
	if Addon.RefreshUI then Addon.RefreshUI() end
end

-- Handlers (addon name -> function(profileName)) are rebuilt every session.
Addon.Handlers = Addon.Handlers or {}

-- ------------------------------------------------------------------
-- Saved variables. They land AFTER this file runs (engine overwrites the
-- global), so every access goes through EnsureDB, never through a file-scope
-- table captured at load. Same pattern TaurenRegret proved on this client.
-- ------------------------------------------------------------------
local function EnsureDB()
	if type(ChungusDB) ~= "table" then ChungusDB = {} end
	local db = ChungusDB
	if type(db.profiles) ~= "table" then db.profiles = {} end
	if type(db.classDefaults) ~= "table" then db.classDefaults = {} end
	if type(db.roleDefaults) ~= "table" then db.roleDefaults = {} end
	if type(ChungusCharDB) ~= "table" then ChungusCharDB = {} end
	if type(db.settings) ~= "table" then db.settings = {} end
	if ChungusCharDB.applied ~= nil and type(ChungusCharDB.applied) ~= "string" then ChungusCharDB.applied = nil end
	if ChungusCharDB.role ~= nil and type(ChungusCharDB.role) ~= "string" then ChungusCharDB.role = nil end
	-- Migrate v1 profiles (actions/snapshots at profile root) into the module layout.
	for name, p in pairs(db.profiles) do
		if type(p) ~= "table" then
			db.profiles[name] = nil
		else
			if type(p.modules) ~= "table" then p.modules = {} end
			if type(p.moduleData) ~= "table" then p.moduleData = {} end
			if type(p.actions) == "table" then
				p.moduleData.ChungusSetup = p.moduleData.ChungusSetup or {}
				p.moduleData.ChungusSetup.actions = p.moduleData.ChungusSetup.actions or p.actions
				p.actions = nil
			end
		end
	end
	-- Stale references (deleted profiles) get cleaned so resolution never dead-ends.
	if ChungusCharDB.applied and not db.profiles[ChungusCharDB.applied] then ChungusCharDB.applied = nil end
	if db.globalDefault and not db.profiles[db.globalDefault] then db.globalDefault = nil end
	for cls, name in pairs(db.classDefaults) do
		if not db.profiles[name] then db.classDefaults[cls] = nil end
	end
	for role, name in pairs(db.roleDefaults) do
		if not db.profiles[name] then db.roleDefaults[role] = nil end
	end
	return db
end
API.EnsureDB = EnsureDB

-- ------------------------------------------------------------------
-- Table helpers (also exposed for child addons).
-- ------------------------------------------------------------------
local function DeepCopy(src, seen)
	if type(src) ~= "table" then return src end
	seen = seen or {}
	if seen[src] then return seen[src] end
	local dst = {}
	seen[src] = dst
	for k, v in pairs(src) do
		if type(k) == "table" then
			dst[DeepCopy(k, seen)] = DeepCopy(v, seen)
		else
			dst[k] = DeepCopy(v, seen)
		end
	end
	return dst
end
API.DeepCopy = DeepCopy

local function WipeTable(t)
	for k in pairs(t) do t[k] = nil end
end

-- ------------------------------------------------------------------
-- Character info helpers.
-- ------------------------------------------------------------------
local function GetClassFile()
	local ok, _, classFile = pcall(UnitClass, "player")
	if ok and classFile then return string.upper(classFile) end
	return nil
end
API.GetClassFile = GetClassFile

-- Persisted cosmetic/settings values (account-wide): minimap angle, visibility...
function API.GetSettings()
	local db = EnsureDB()
	if type(db.settings) ~= "table" then db.settings = {} end
	return db.settings
end

-- Layout preferences shared by every tab (account-wide). Returned table is
-- live: writing a field persists it; call Chungus.Core.RelayoutPages() after.
API.UI_DEFAULTS = {
	padding = 8,     -- spacing around page content
	rowGap = 4,      -- vertical gap between Setup action rows
	fontSize = 12,   -- label/button text size on tab pages
	windowWidth = 660,
	windowHeight = 520,
}
local UI_LIMITS = {
	padding = { 0, 32 },
	rowGap = { 0, 20 },
	fontSize = { 9, 18 },
	windowWidth = { 660, 1900 },
	windowHeight = { 360, 1400 },
}

function API.GetUISettings()
	local s = API.GetSettings()
	if type(s.ui) ~= "table" then s.ui = {} end
	local ui = s.ui
	for key, defaultValue in pairs(API.UI_DEFAULTS) do
		local value = ui[key]
		if type(value) ~= "number" then
			ui[key] = defaultValue
		else
			local limits = UI_LIMITS[key]
			if limits then
				if value < limits[1] then value = limits[1] end
				if value > limits[2] then value = limits[2] end
				ui[key] = value
			end
		end
	end
	return ui
end

function API.ResetUISettings()
	local ui = API.GetUISettings()
	for key, value in pairs(API.UI_DEFAULTS) do ui[key] = value end
	return ui
end

local ROLES = { "none", "tank", "healer", "dps" }
API.ROLES = ROLES

-- ------------------------------------------------------------------
-- Delayed queue. This client may lack C_Timer; a tiny OnUpdate queue is
-- guaranteed and lets actions stagger (chat command -> response needs the
-- previous one to finish).
-- ------------------------------------------------------------------
Addon.Queue = {}

function Addon.RunAfter(delay, fn)
	tinsert(Addon.Queue, { at = GetTime() + (delay or 0), fn = fn })
end

local queueFrame = CreateFrame("FRAME", "_ChungusQueue")
queueFrame:SetScript("OnUpdate", function()
	local now = GetTime()
	for i = #Addon.Queue, 1, -1 do
		local item = Addon.Queue[i]
		if item.at <= now then
			table.remove(Addon.Queue, i)
			local ok, err = pcall(item.fn)
			if not ok then print("[Chungus] action error: " .. tostring(err)) end
		end
	end
end)

-- ------------------------------------------------------------------
-- Slash command runner (tier 2). Types the command into a chat editbox and
-- sends it, exactly as if the player typed it.
-- ------------------------------------------------------------------
function API.RunCommand(cmd)
	if type(cmd) ~= "string" or cmd == "" then return end
	if string.sub(cmd, 1, 1) ~= "/" then cmd = "/" .. cmd end
	local ok, err = pcall(function()
		local editbox = ChatEdit_ChooseBoxForSend(DEFAULT_CHAT_FRAME)
		ChatEdit_ActivateChat(editbox)
		editbox:SetText(cmd)
		ChatEdit_SendText(editbox)
		ChatEdit_DeactivateChat(editbox)
	end)
	if not ok then
		print("[Chungus] Could not run command '" .. cmd .. "': " .. tostring(err))
	end
end

-- ------------------------------------------------------------------
-- Handler registry (tier 1). Child addons or future code register per-addon
-- profile APIs here; the Setup module shows API actions for handlers present.
-- ------------------------------------------------------------------
function API.RegisterHandler(addonName, fn)
	if type(addonName) == "string" and type(fn) == "function" then
		Addon.Handlers[addonName] = fn
	end
end

function API.GetHandler(addonName)
	return Addon.Handlers[addonName]
end

function API.GetHandlerNames()
	local names = {}
	for name in pairs(Addon.Handlers) do tinsert(names, name) end
	table.sort(names)
	return names
end

-- Built-in handlers for addons that expose a real profile API.
API.RegisterHandler("Details", function(profileName)
	local D = G.Details
	if not D then
		error("Details! is not loaded")
	end
	-- Details exposes SetProfile on its DetailsAPI table; _G.Details has
	-- ApplyProfile (same thing, with its own save step).
	local setter = type(D.ApplyProfile) == "function" and D.ApplyProfile
		or (G.DetailsAPI and G.DetailsAPI.SetProfile)
	if type(setter) ~= "function" then
		error("Details! has no profile API")
	end
	if G.DetailsAPI and setter == G.DetailsAPI.SetProfile then
		G.DetailsAPI:SetProfile(profileName)
	else
		setter(D, profileName)
	end
end)

-- ------------------------------------------------------------------
-- AceDB bridge (tier 1b). Most profile-aware addons on this client use
-- AceDB-3.0 (Bartender4, Plater, Questie, HandyNotes, Mapster, Decursive,
-- RatingBuster, Spoken, AtlasLoot...). Every AceDB object ever created
-- registers itself on the shared library table -- LibStub dedupes AceDB-3.0
-- across addons -- so we can discover them all without hardcoding per addon:
--   LibStub("AceDB-3.0").db_registry[db] = true
-- A db object exposes :SetProfile(name), :GetProfiles(), .keys.profile (the
-- active profile) and .sv (its saved-variable table). Namespaces have
-- .parent set and follow their parent db, so they are skipped.
--
-- Naming a db: scan _G once for a table whose .db field IS the object
-- (Bartender4.db, Plater.db, Questie.db) and for the global table that the
-- db's .sv points at (its saved-variable name).
-- ------------------------------------------------------------------
local AceCache = nil

-- Prefer saved-variable-looking names when several globals alias one table.
local function SavedVarScore(name)
	local score = 0
	if string.sub(name, -2) == "DB" then score = score + 3 end
	if string.sub(name, -6) == "Config" then score = score + 2 end
	if string.sub(name, -8) == "Settings" then score = score + 2 end
	if string.find(name, "DB", 1, true) then score = score + 1 end
	return score
end

local function ReadAceProfiles(db)
	local profiles = {}
	local ok, names = pcall(db.GetProfiles, db)
	if not ok or type(names) ~= "table" then names = db.profiles end
	if type(names) == "table" then
		-- AceDB returns { [name] = true }; tolerate a plain array of names too.
		for key, value in pairs(names) do
			if type(key) == "string" then
				tinsert(profiles, key)
			elseif type(value) == "string" then
				tinsert(profiles, value)
			end
		end
	end
	table.sort(profiles)
	return profiles
end

local function ReadAceCurrent(db)
	local current = db.keys and db.keys.profile or nil
	if not current and type(db.GetCurrentProfile) == "function" then
		local ok, c = pcall(db.GetCurrentProfile, db)
		if ok then current = c end
	end
	return current
end

local function BuildAceList()
	local AceDB = LibStub and LibStub("AceDB-3.0", true)
	local registry = AceDB and AceDB.db_registry
	if type(registry) ~= "table" then return {} end

	-- One pass over _G to name every db (owner table) and saved-variable table.
	local ownerByDb, nameByTable, scoreByTable = {}, {}, {}
	for name, value in pairs(G) do
		if type(name) == "string" and type(value) == "table" then
			local ownerDb = rawget(value, "db")
			if ownerDb ~= nil and ownerByDb[ownerDb] == nil then
				ownerByDb[ownerDb] = name
			end
			local score = SavedVarScore(name)
			local best = scoreByTable[value]
			if best == nil or score > best then
				scoreByTable[value] = score
				nameByTable[value] = name
			end
		end
	end

	local list = {}
	for db in pairs(registry) do
		if type(db) == "table" and type(db.SetProfile) == "function" and not db.parent then
			local owner = ownerByDb[db]
			local savedvar = db.sv and nameByTable[db.sv] or nil
			tinsert(list, {
				db = db,
				owner = owner,
				savedvar = savedvar,
				label = owner or savedvar or "?",
				current = ReadAceCurrent(db),
				profiles = ReadAceProfiles(db),
			})
		end
	end
	table.sort(list, function(a, b) return string.lower(a.label) < string.lower(b.label) end)
	return list
end

-- Cached because it walks _G; force = true rebuilds (e.g. after /reload or a
-- late-loading addon created its db).
function API.GetAceDatabases(force)
	if force or not AceCache then AceCache = BuildAceList() end
	return AceCache
end

-- Accepts the addon name ("Bartender4") or its saved-variable name
-- ("Bartender4DB"), case-insensitively.
function API.GetAceEntry(key)
	if type(key) ~= "string" or key == "" then return nil end
	local want = string.lower(string.trim(key))
	local function Find(list)
		for _, entry in ipairs(list) do
			if (entry.owner and string.lower(entry.owner) == want)
				or (entry.savedvar and string.lower(entry.savedvar) == want) then
				return entry
			end
		end
	end
	local wasCached = AceCache ~= nil
	local entry = Find(API.GetAceDatabases())
	if entry or not wasCached then return entry end
	-- Rebuild once on a miss: a load-on-demand addon may have created its db
	-- after the last scan.
	return Find(API.GetAceDatabases(true))
end

-- Plater pops a "reload now?" dialog from its OnProfileChanged callback.
-- The switch itself is complete without a reload, so mute the dialog for the
-- duration of the synchronous call (and restore it no matter what).
local function SetPlaterProfile(db, profileName)
	local DF = G.DetailsFramework
	local prompt = DF and DF.ShowPromptPanel
	if type(prompt) == "function" then DF.ShowPromptPanel = function() end end
	local ok, err = pcall(db.SetProfile, db, profileName)
	if type(prompt) == "function" then DF.ShowPromptPanel = prompt end
	if not ok then error(err, 0) end
end

-- Switch one AceDB addon to an existing profile. Raises on unknown addon /
-- profile / combat so the caller (RunAction) can print why nothing happened.
function API.SetAceProfile(key, profileName)
	local entry = API.GetAceEntry(key)
	if not entry then
		error("no AceDB database for '" .. tostring(key) .. "' (is that addon loaded?)")
	end
	if type(profileName) ~= "string" or profileName == "" then
		error("no profile name given for " .. entry.label)
	end

	-- Read live, never the cache: the player may have switched profiles in the
	-- addon's own UI since the last scan.
	entry.current = ReadAceCurrent(entry.db)
	entry.profiles = ReadAceProfiles(entry.db)

	local exists = false
	for _, name in ipairs(entry.profiles) do
		if name == profileName then exists = true; break end
	end
	if not exists then
		error(("profile '%s' does not exist in %s (available: %s)"):format(
			profileName, entry.label,
			#entry.profiles > 0 and table.concat(entry.profiles, ", ") or "none"))
	end
	if entry.current == profileName then return "already active" end
	if G.InCombatLockdown and G.InCombatLockdown() then
		error("cannot switch " .. entry.label .. " profile during combat")
	end

	if entry.owner == "Plater" or entry.savedvar == "PlaterDB" then
		SetPlaterProfile(entry.db, profileName)
	else
		entry.db:SetProfile(profileName)
	end
	entry.current = profileName
	return "ok"
end

-- ------------------------------------------------------------------
-- Profile support for addons that are NOT AceDB. Two sources:
--   1. built-in providers (Details), where the API is known;
--   2. runtime detection: the addon's own functions (Config.GetProfileNames /
--      Config.ChangeProfile style) or, failing that, its saved variables
--      (CONFIG.Profiles table + a CURRENT_PROFILE global).
-- AceDB addons are read straight from db_registry instead.
-- ------------------------------------------------------------------
local ProfileProviders = {
	Details = {
		list = function()
			local D = G.Details
			if not D or type(D.GetProfileList) ~= "function" then return {} end
			local ok, names = pcall(D.GetProfileList, D)
			if not ok or type(names) ~= "table" then return {} end
			local out = {}
			for _, name in ipairs(names) do
				if type(name) == "string" then tinsert(out, name) end
			end
			table.sort(out)
			return out
		end,
		current = function()
			local D = G.Details
			if D and type(D.GetCurrentProfileName) == "function" then
				local ok, name = pcall(D.GetCurrentProfileName, D)
				if ok then return name end
			end
		end,
		switch = function(name)
			local D = G.Details
			if type(D.ApplyProfile) == "function" then
				D:ApplyProfile(name)
			elseif G.DetailsAPI and type(G.DetailsAPI.SetProfile) == "function" then
				G.DetailsAPI:SetProfile(name)
			else
				error("Details has no profile API")
			end
		end,
	},
}
API.ProfileProviders = ProfileProviders

-- Function names addons commonly use for their profile system.
local PROFILE_LIST_FNS = {
	"GetProfileNames", "GetProfileList", "GetProfilesList", "GetProfileKeys",
	"GetProfiles", "ListProfiles",
}
local PROFILE_SET_FNS = {
	"ChangeProfile", "SetProfile", "ApplyProfile", "LoadProfile",
	"ActivateProfile", "SwitchProfile", "SetCurrentProfile",
}
local PROFILE_CURRENT_FNS = {
	"GetCurrentProfileName", "GetCurrentProfileKey", "GetCurrentProfile",
	"GetProfileName", "GetCurrentProfileKeyName",
}
-- Sub-tables worth probing on an addon's global table.
local PROFILE_SUBTABLES = {
	"Config", "Configuration", "API", "Options", "Settings", "Setting",
	"Profile", "Profiles", "DB", "db", "Util", "Utilities",
}

local function FirstFunction(tbl, names)
	for _, name in ipairs(names) do
		if type(tbl[name]) == "function" then return name end
	end
end

-- Normalise whatever a "list profiles" function returns into a sorted array:
-- { [name] = true }, { [name] = data } and plain arrays all work.
local function ToNameList(value)
	local out = {}
	if type(value) ~= "table" then return out end
	for key, v in pairs(value) do
		if type(key) == "string" then
			tinsert(out, key)
		elseif type(v) == "string" then
			tinsert(out, v)
		end
	end
	table.sort(out)
	return out
end

local DumpSignature  -- defined below; used for dot/colon detection

-- Profile helpers come in two shapes: methods (function t:SetProfile(p), which
-- need the table as 'self') and plain functions (function t.SetProfile(p)).
-- The dumped signature names the first parameter, so 'self' means method.
-- AceDB objects and Details are methods; Baganator's Config.ChangeProfile is
-- dot-style, and calling it colon-style passes the table as the new name.
local function ProfileCaller(tbl, fn)
	local method = true
	local sig = DumpSignature(fn)
	if sig then method = (sig.first == "self") end
	if method then
		return function(...) return fn(tbl, ...) end
	end
	return function(...) return fn(...) end
end

-- "<ADDON>_CURRENT_PROFILE" saved variable, keyed off the addon global name.
local function CurrentProfileGlobal(key)
	local value = G[string.upper(key) .. "_CURRENT_PROFILE"]
	if type(value) == "string" and value ~= "" then return value end
	return nil
end

-- Longest common shape: an addon's own profile functions, reachable from its
-- global table or a well-known sub-table. Returns nil when nothing matches.
local DetectedAPIs = {}
function API.DetectProfileAPI(key)
	if type(key) ~= "string" or key == "" then return nil end
	if DetectedAPIs[key] ~= nil then return DetectedAPIs[key] or nil end

	local root = G[key]
	if type(root) ~= "table" then DetectedAPIs[key] = false; return nil end

	local candidates = { { tbl = root, path = "" } }
	for _, sub in ipairs(PROFILE_SUBTABLES) do
		if type(root[sub]) == "table" then
			tinsert(candidates, { tbl = root[sub], path = sub })
		end
	end

	for _, cand in ipairs(candidates) do
		local listFn = FirstFunction(cand.tbl, PROFILE_LIST_FNS)
		local setFn = FirstFunction(cand.tbl, PROFILE_SET_FNS)
		if listFn and setFn then
			local currentFn = FirstFunction(cand.tbl, PROFILE_CURRENT_FNS)
			local api = {
				source = "detected",
				path = cand.path,
				list = function()
					local ok, value = pcall(cand.tbl[listFn], cand.tbl)
					if not ok then return {} end
					return ToNameList(value)
				end,
				current = function()
					if currentFn then
						local ok, value = pcall(cand.tbl[currentFn], cand.tbl)
						if ok and type(value) == "string" then return value end
					end
					local keys = cand.tbl.keys or cand.tbl.db and cand.tbl.db.keys
					if type(keys) == "table" and type(keys.profile) == "string" then
						return keys.profile
					end
					return CurrentProfileGlobal(key)
				end,
				switch = function(name)
					local ok, err = pcall(ProfileCaller(cand.tbl, cand.tbl[setFn]), name)
					if not ok then error(err, 0) end
				end,
			}
			DetectedAPIs[key] = api
			return api
		end
	end
	DetectedAPIs[key] = false
	return nil
end

-- Some addons keep their API private (local addonTable = ...), so the profile
-- functions are not reachable from _G. Lua closures still hold that table as
-- an upvalue, so walk the upvalues of the addon's own global functions a
-- bounded distance looking for a table with a list+set profile pair. Read
-- only: nothing is called here.
local DeepDetected = {}
local function ProfilePair(tbl)
	if type(tbl) ~= "table" then return nil end
	local listFn = FirstFunction(tbl, PROFILE_LIST_FNS)
	local setFn = FirstFunction(tbl, PROFILE_SET_FNS)
	if listFn and setFn then
		return { tbl = tbl, listFn = listFn, setFn = setFn,
			currentFn = FirstFunction(tbl, PROFILE_CURRENT_FNS) }
	end
end

function API.DeepDetectProfileAPI(key)
	if type(key) ~= "string" or key == "" then return nil end
	if DeepDetected[key] ~= nil then return DeepDetected[key] or nil end

	local root = G[key]
	if type(root) ~= "table" or type(debug) ~= "table"
		or type(debug.getupvalue) ~= "function" then
		DeepDetected[key] = false
		return nil
	end

	-- Seeds: functions on the addon table and its well-known sub-tables.
	local seeds = {}
	local function Seed(tbl)
		for _, value in pairs(tbl) do
			if type(value) == "function" then tinsert(seeds, value) end
		end
	end
	Seed(root)
	for _, sub in ipairs(PROFILE_SUBTABLES) do
		if type(root[sub]) == "table" then Seed(root[sub]) end
	end

	local queue, visited, head, nodes = {}, { [root] = true, [G] = true }, 1, 0
	for _, fn in ipairs(seeds) do
		for i = 1, 16 do
			local ok, name, value = pcall(debug.getupvalue, fn, i)
			if not ok or name == nil then break end
			if type(value) == "table" then tinsert(queue, value) end
		end
		if #queue > 500 then break end
	end

	while head <= #queue and nodes < 400 do
		local tbl = queue[head]
		head = head + 1
		if type(tbl) == "table" and not visited[tbl] then
			visited[tbl] = true
			nodes = nodes + 1
			local pair = ProfilePair(tbl)
			if not pair then
				for _, sub in ipairs(PROFILE_SUBTABLES) do
					local candidate = tbl[sub]
					if type(candidate) == "table" and not visited[candidate] then
						visited[candidate] = true
						pair = ProfilePair(candidate)
						if pair then break end
					end
				end
			end
			if pair then
				local api = {
					source = "detected",
					path = "upvalue",
					list = function()
						local ok, value = pcall(pair.tbl[pair.listFn], pair.tbl)
						if not ok then return {} end
						return ToNameList(value)
					end,
					current = function()
						if pair.currentFn then
							local ok, value = pcall(pair.tbl[pair.currentFn], pair.tbl)
							if ok and type(value) == "string" then return value end
						end
						local keys = pair.tbl.keys
						if type(keys) == "table" and type(keys.profile) == "string" then
							return keys.profile
						end
						return CurrentProfileGlobal(key)
					end,
					switch = function(name)
						local ok, err = pcall(ProfileCaller(pair.tbl, pair.tbl[pair.setFn]), name)
						if not ok then error(err, 0) end
					end,
				}
				DeepDetected[key] = api
				return api
			end
			-- Shallow widen: nested tables of this one, capped.
			local added = 0
			for _, value in pairs(tbl) do
				if type(value) == "table" and not visited[value] then
					tinsert(queue, value)
					added = added + 1
					if added >= 30 then break end
				end
			end
		end
	end
	DeepDetected[key] = false
	return nil
end

local function SplitList(text)
	local out = {}
	for part in string.gmatch(text or "", "([^,]+)") do
		local trimmed = part:match("^%s*(.-)%s*$") or ""
		if trimmed ~= "" then tinsert(out, trimmed) end
	end
	return out
end

local function GetAddonMetadataSafe(addonName, field)
	local f = (C_AddOns and C_AddOns.GetAddOnMetadata) or G.GetAddOnMetadata
	if type(f) ~= "function" then return nil end
	local ok, value = pcall(f, addonName, field)
	if ok then return value end
end

-- Fallback for addons that keep profiles purely in saved variables:
--   ADDON_CONFIG.Profiles = { [name] = {...} }   +   ADDON_CURRENT_PROFILE = name
-- Switching writes the global, which the addon reads at login, so it applies
-- on the next /reload (reported to the caller via requiresReload).
local SavedvarAPIs = {}
function API.DetectSavedvarProfiles(key)
	if type(key) ~= "string" or key == "" then return nil end
	if SavedvarAPIs[key] ~= nil then return SavedvarAPIs[key] or nil end

	local savedvars = SplitList(GetAddonMetadataSafe(key, "SavedVariables"))
	for _, extra in ipairs(SplitList(GetAddonMetadataSafe(key, "SavedVariablesPerCharacter"))) do
		tinsert(savedvars, extra)
	end
	local config, profiles
	for _, sv in ipairs(savedvars) do
		local tbl = G[sv]
		if type(tbl) == "table" then
			local candidate = tbl.Profiles or tbl.profiles
			if type(candidate) == "table" and next(candidate) ~= nil then
				config, profiles = sv, candidate
				break
			end
		end
	end
	if not profiles then SavedvarAPIs[key] = false; return nil end

	local upper = string.upper(key)
	local varName = upper .. "_CURRENT_PROFILE"
	if varName == upper .. "_PROFILE" then varName = upper .. "_CURRENT_PROFILE" end
	local current
	if type(G[varName]) == "string" then
		current = G[varName]
	else
		-- Any <ADDON>_*PROFILE* string global will do.
		local prefix = upper .. "_"
		for name, value in pairs(G) do
			if type(name) == "string" and type(value) == "string"
				and string.sub(name, 1, #prefix) == prefix
				and string.find(name, "PROFILE", 1, true) then
				varName, current = name, value
				break
			end
		end
	end

	local api = {
		source = "savedvar",
		savedvar = config,
		requiresReload = true,
		list = function() return ToNameList(profiles) end,
		current = function()
			if varName and type(G[varName]) == "string" then return G[varName] end
			return current
		end,
		switch = function(name)
			if not varName then
				error("cannot find the current-profile variable for " .. tostring(key))
			end
			-- Writing the global is enough: the addon reads it at login.
			G[varName] = name
			current = name
		end,
	}
	SavedvarAPIs[key] = api
	return api
end

-- Diagnostic for /chungusdebug: why savedvar profile detection found nothing.
-- Returns nil when the addon does not declare saved variables at all (nothing
-- to report), otherwise a one-line reason.
function API.DescribeSavedvarDetection(key)
	local raw = GetAddonMetadataSafe(key, "SavedVariables")
	local perChar = GetAddonMetadataSafe(key, "SavedVariablesPerCharacter")
	if (not raw or raw == "") and (not perChar or perChar == "") then return nil end
	local names = SplitList(raw)
	for _, extra in ipairs(SplitList(perChar)) do tinsert(names, extra) end
	local found = {}
	for _, sv in ipairs(names) do
		local tbl = G[sv]
		if type(tbl) ~= "table" then
			tinsert(found, sv .. "=missing")
		else
			local profiles = tbl.Profiles or tbl.profiles
			if type(profiles) ~= "table" then
				tinsert(found, sv .. "=no.Profiles")
			elseif next(profiles) == nil then
				tinsert(found, sv .. "=empty")
			else
				tinsert(found, sv .. "=ok")
			end
		end
	end
	return table.concat(found, ",")
end

-- Everything Chungus can switch profiles on: AceDB dbs, built-in providers
-- and addons detected at runtime. deep = true also walks closures looking for
-- a private addon table (slow-ish, so the UI asks for it, login does not).
function API.GetProfileTargets(force, deep)
	if force then
		DetectedAPIs = {}
		DeepDetected = {}
		SavedvarAPIs = {}
	end
	local targets, seen = {}, {}
	for _, entry in ipairs(API.GetAceDatabases(force)) do
		local key = entry.owner or entry.savedvar
		if key and not seen[key] then
			seen[key] = true
			tinsert(targets, { key = key, label = key, source = "AceDB",
				current = ReadAceCurrent(entry.db) })
		end
	end
	for key, provider in pairs(ProfileProviders) do
		if not seen[key] and G[key] then
			seen[key] = true
			tinsert(targets, { key = key, label = key, source = "provider",
				current = provider.current() })
		end
	end
	for _, addon in ipairs(API.GetInstalledAddons(true)) do
		local key = addon.name
		-- Never offer the Chungus modules themselves: Chungus.API has
		-- GetProfiles/ApplyProfile, so the detector would happily match it and
		-- an apply would recurse into itself.
		if not seen[key] and string.sub(key, 1, 7) ~= "Chungus" then
			local api = API.DetectProfileAPI(key)
				or (deep and API.DeepDetectProfileAPI(key))
			if not api then
				local savedvar = API.DetectSavedvarProfiles(key)
				if savedvar then
					seen[key] = true
					tinsert(targets, { key = key, label = key, source = "savedvar",
						current = savedvar.current() })
				end
			else
				seen[key] = true
				tinsert(targets, { key = key, label = key, source = api.source,
					current = api.current() })
			end
		end
	end
	table.sort(targets, function(a, b)
		return string.lower(a.label) < string.lower(b.label)
	end)
	return targets
end

-- { label, list = {names}, current = name, source = ...,
--   switch = function(name), requiresReload = bool } or nil.
function API.GetAddonProfiles(key)
	if type(key) ~= "string" or key == "" then return nil end
	if string.sub(key, 1, 7) == "Chungus" then return nil end
	local ace = API.GetAceEntry(key)
	if ace then
		return {
			label = ace.label,
			list = ReadAceProfiles(ace.db),
			current = ReadAceCurrent(ace.db),
			source = "AceDB",
			switch = function(name) API.SetAceProfile(key, name) end,
		}
	end
	local provider = ProfileProviders[key]
	if provider then
		return {
			label = key,
			list = provider.list(),
			current = provider.current(),
			source = "provider",
			switch = function(name) provider.switch(name) end,
		}
	end
	local api = API.DetectProfileAPI(key) or API.DeepDetectProfileAPI(key)
		or API.DetectSavedvarProfiles(key)
	if api then
		return {
			label = key,
			list = api.list(),
			current = api.current(),
			source = api.source,
			requiresReload = api.requiresReload,
			switch = function(name) api.switch(name) end,
		}
	end
	return nil
end

-- Switch any supported addon to an existing profile. Raises with a useful
-- message when the addon/profile is unknown so RunAction can print why.
function API.SetAddonProfile(key, profileName)
	local target = API.GetAddonProfiles(key)
	if not target then
		error(tostring(key) .. " has no profile API (pick a function instead)")
	end
	if type(profileName) ~= "string" or profileName == "" then
		error("no profile name given for " .. tostring(key))
	end
	local exists = false
	for _, name in ipairs(target.list) do
		if name == profileName then exists = true; break end
	end
	if not exists then
		error(("profile '%s' does not exist in %s (available: %s)"):format(
			profileName, tostring(key),
			#target.list > 0 and table.concat(target.list, ", ") or "none"))
	end
	if target.current == profileName then return "already active" end
	target.switch(profileName)
	return target.requiresReload and "reload" or "ok"
end

-- One handler per switchable addon, so Setup rows can just name the addon with
-- an empty function box. Curated handlers win. force = true rescans (used at
-- login, so late-loading addons are picked up).
function API.RegisterAceHandlers(force)
	for _, target in ipairs(API.GetProfileTargets(force)) do
		local key = target.key
		if key and not Addon.Handlers[key] then
			API.RegisterHandler(key, function(profileName)
				API.SetAddonProfile(key, profileName)
			end)
		end
	end
end

-- Names on an Ace addon object that are library plumbing, not addon API.
local NOISE_PREFIXES = {
	"Ace", "Lib", "On", "Register", "Unregister", "Embed", "Hook", "Unhook",
	"Secure", "Raw", "Schedule", "Cancel", "Send", "Print", "Iterate",
	"NewModule", "GetModule", "Enable", "Disable", "SetEnabledState",
}
local NOISE_KEYS = {
	db = true, sv = true, options = true, defaults = true, modules = true,
	orderedModules = true, modulePrototype = true, CONFIG_VERSION = true,
	Util = true, Compat = true, locale = true, profileKeys = true,
	Log = true, DB = true,
}

function API.IsNoisyMember(name)
	if type(name) ~= "string" then return true end
	if NOISE_KEYS[name] then return true end
	for _, prefix in ipairs(NOISE_PREFIXES) do
		if string.sub(name, 1, #prefix) == prefix then return true end
	end
	return false
end

-- Follow a dotted member path ("API.SetCategoryViewMode") from the addon's
-- global table. Returns the owner table and the function.
function API.ResolveMember(key, member)
	local obj = G[key]
	if type(obj) ~= "table" or type(member) ~= "string" or member == "" then
		return nil, nil
	end
	local owner = obj
	for part in string.gmatch(member, "[^%.]+") do
		if type(owner) ~= "table" then return nil, nil end
		owner = owner[part]
		if owner == nil then return nil, nil end
	end
	if type(owner) ~= "function" then return nil, nil end
	-- Owner is the table just before the final segment.
	local parent = obj
	local parts = {}
	for part in string.gmatch(member, "[^%.]+") do tinsert(parts, part) end
	for i = 1, #parts - 1 do
		parent = type(parent) == "table" and parent[parts[i]] or nil
		if not parent then return nil, nil end
	end
	return parent, owner
end

-- Enumerate callable functions exposed by ONE addon, including one level of
-- sub-tables, as dotted paths ("API.RegisterCornerWidget"). Scoped strictly
-- to that addon's global table; unrelated globals are never scanned.
local MEMBER_MAX = 200
function API.GetAddonFunctions(key)
	if type(key) ~= "string" or key == "" then return {} end
	local out = {}
	local prof = API.GetAddonProfiles(key)
	if prof then
		tinsert(out, {
			member = "",
			label = "switch profile",
			params = 1,
			names = { "profile" },
			hint = prof.source,
		})
	end

	local root = G[key]
	if type(root) ~= "table" then return out end

	local found, visited = {}, {}
	local function Walk(tbl, prefix, depth)
		if type(tbl) ~= "table" or visited[tbl] then return end
		visited[tbl] = true
		for name, value in pairs(tbl) do
			if #found >= MEMBER_MAX then return end
			if type(name) == "string" and not API.IsNoisyMember(name) then
				local path = prefix == "" and name or (prefix .. "." .. name)
				if type(value) == "function" then
					tinsert(found, path)
				elseif depth < 2 and type(value) == "table"
					and not API.IsNoisyMember(name) then
					Walk(value, path, depth + 1)
				end
			end
		end
	end
	Walk(root, "", 1)

	-- Profile setters first, then alphabetical.
	local function Score(path)
		local last = string.match(path, "([^%.]+)$") or path
		local lower = string.lower(last)
		local score = 0
		if string.find(lower, "profile", 1, true) then score = score + 3 end
		if string.sub(lower, 1, 3) == "set" then score = score + 2 end
		return score
	end
	table.sort(found, function(a, b)
		local sa, sb = Score(a), Score(b)
		if sa ~= sb then return sa > sb end
		return string.lower(a) < string.lower(b)
	end)
	for _, path in ipairs(found) do
		if not (prof and (path == "SetProfile" or path == "GetProfile")) then
			local desc = API.DescribeFunction(key, path)
			tinsert(out, {
				member = path,
				label = path,
				params = desc.params,
				names = desc.names,
			})
		end
	end
	return out
end

-- WoW's Lua 5.1 does not expose nparams in debug.getinfo, so read the
-- function's dumped header directly: declared parameter count, and the name of
-- the first parameter ("self" means it is called with a colon, otherwise the
-- function is a plain dotted call and takes no implicit self).
function DumpSignature(fn)
	if type(string.dump) ~= "function" then return nil end
	local ok, dumped = pcall(string.dump, fn)
	if not ok or type(dumped) ~= "string" or #dumped < 16 then return nil end
	if string.sub(dumped, 1, 4) ~= "\27Lua" then return nil end
	local sizeofInt = string.byte(dumped, 8) or 4
	local sizeofSizeT = string.byte(dumped, 9) or 4
	local sizeofNumber = string.byte(dumped, 11) or 8
	if sizeofInt < 1 or sizeofInt > 8 then return nil end
	if sizeofSizeT ~= 4 and sizeofSizeT ~= 8 then return nil end
	if sizeofNumber ~= 4 and sizeofNumber ~= 8 then return nil end

	local total = #dumped
	local pos = 13  -- past the 12-byte chunk header
	local function Bounds(n)
		return pos + n - 1 <= total
	end
	local function ReadUInt(bytes)
		if not Bounds(bytes) then return nil end
		local value = 0
		for i = bytes, 1, -1 do
			local b = string.byte(dumped, pos + i - 1)
			if not b then return nil end
			value = value * 256 + b
		end
		pos = pos + bytes
		return value
	end
	local function ReadString()
		local len = ReadUInt(sizeofSizeT)
		if not len then return nil end
		if len == 0 then return "" end
		if not Bounds(len) then return nil end
		local value = string.sub(dumped, pos, pos + len - 1)
		pos = pos + len
		-- Lua 5.1 dumps strings with their terminating NUL included.
		if string.sub(value, -1) == "\0" then
			value = string.sub(value, 1, -2)
		end
		return value
	end
	local function Skip(bytes)
		if not Bounds(bytes) then return nil end
		pos = pos + bytes
		return true
	end

	-- Recursive body reader; records the outermost function's signature.
	local signature
	local function ReadFunction(depth)
		if not ReadString() then return false end           -- source
		if not ReadUInt(sizeofInt) then return false end    -- linedefined
		if not ReadUInt(sizeofInt) then return false end    -- lastlinedefined
		if not Skip(2) then return false end                -- nups, numparams
		local params = string.byte(dumped, pos - 1) or 0
		if not Skip(2) then return false end                -- is_vararg, maxstacksize

		local ncode = ReadUInt(sizeofInt)
		if not ncode or not Skip(ncode * 4) then return false end
		local nconst = ReadUInt(sizeofInt)
		if not nconst then return false end
		for _ = 1, nconst do
			local kind = string.byte(dumped, pos)
			if not kind or not Skip(1) then return false end
			if kind == 1 then                                 -- boolean
				if not Skip(1) then return false end
			elseif kind == 3 then                             -- number
				if not Skip(sizeofNumber) then return false end
			elseif kind == 4 then                             -- string
				if not ReadString() then return false end
			elseif kind ~= 0 then                             -- nil
				return false
			end
		end
		local nproto = ReadUInt(sizeofInt)
		if not nproto then return false end
		for _ = 1, nproto do
			if not ReadFunction(depth + 1) then return false end
		end

		local nline = ReadUInt(sizeofInt)
		if not nline or not Skip(nline * sizeofInt) then return false end
		local nloc = ReadUInt(sizeofInt)
		if not nloc then return false end
		local names = {}
		for i = 1, nloc do
			local name = ReadString()
			if not name then return false end
			if not Skip(2 * sizeofInt) then return false end
			if i <= params then names[i] = name end
		end
		local nup = ReadUInt(sizeofInt)
		if not nup then return false end
		for _ = 1, nup do
			if not ReadString() then return false end
		end
		if depth == 0 then
			signature = { params = params, first = names[1] }
		end
		return true
	end

	if not ReadFunction(0) then return nil end
	return signature
end

-- What does _G[key]:member(...) need? Returns argument count (self excluded)
-- and whether self must be passed.
function API.DescribeFunction(key, member)
	if type(member) ~= "string" or member == "" then
		return { params = 1, names = { "profile" }, colon = false }
	end
	local parent, fn = API.ResolveMember(key, member)
	if type(fn) ~= "function" then
		return { params = 1, names = { "arg 1" }, colon = true }
	end

	local declared, colon
	if type(debug) == "table" and type(debug.getinfo) == "function" then
		local ok, info = pcall(debug.getinfo, fn, "u")
		if ok and type(info) == "table" and type(info.nparams) == "number" then
			declared = info.nparams
		end
	end
	local sig = not declared and DumpSignature(fn) or nil
	if not declared and sig then
		declared = sig.params
		colon = (sig.first == "self")
	end
	if not declared then
		-- Unknown (usually a C function): assume a method call with one arg.
		declared, colon = 2, true
	end
	if colon == nil then
		-- nparams came from debug.getinfo without a name: assume method style.
		colon = true
	end

	local params = declared - (colon and 1 or 0)
	if params < 0 then params = 0 end
	if params > 4 then params = 4 end
	local names = {}
	for i = 1, params do names[i] = "arg " .. i end
	if string.find(string.lower(member), "profile", 1, true) then names[1] = "profile" end
	return { params = params, names = names, colon = colon }
end

-- ------------------------------------------------------------------
-- Addon detection (for the Setup module's hints).
-- ------------------------------------------------------------------
local function GetNumAddOnsSafe()
	local f = C_AddOns and C_AddOns.GetNumAddOns or GetNumAddOns
	if type(f) ~= "function" then return 0 end
	return f()
end

function API.GetInstalledAddons(loadedOnly)
	local list = {}
	local getInfo = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if type(getInfo) ~= "function" then return list end
	for i = 1, GetNumAddOnsSafe() do
		local ok, name, title = pcall(getInfo, i)
		if ok and name then
			local loaded = false
			if type(isLoaded) == "function" then
				local lok, l = pcall(isLoaded, name)
				loaded = lok and l or false
			end
			if not loadedOnly or loaded then
				tinsert(list, { name = name, title = title or name, loaded = loaded })
			end
		end
	end
	table.sort(list, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	return list
end

-- All slash commands currently registered. Addons register commands by setting
-- globals named SLASH_<something>N = "/cmd", so scanning _G finds them all —
-- there is no direct "list commands" API.
local slashCache = nil
function API.GetSlashCommands(force)
	if slashCache and not force then return slashCache end
	local seen, list = {}, {}
	for k, v in pairs(G) do
		if type(k) == "string" and string.sub(k, 1, 6) == "SLASH_"
			and type(v) == "string" and string.sub(v, 1, 1) == "/" then
			local c = string.lower(v)
			if not seen[c] then
				seen[c] = true
				tinsert(list, c)
			end
		end
	end
	table.sort(list)
	slashCache = list
	return list
end

-- ------------------------------------------------------------------
-- Profile CRUD.
-- ------------------------------------------------------------------
function API.CreateProfile(name)
	name = type(name) == "string" and string.trim(name) or ""
	if name == "" then return nil, "empty name" end
	local db = EnsureDB()
	if db.profiles[name] then return db.profiles[name], "exists" end
	local profile = { onLogin = false, modules = {}, moduleData = {}, snapshots = {} }
	db.profiles[name] = profile
	return profile, "created"
end

function API.DeleteProfile(name)
	local db = EnsureDB()
	db.profiles[name] = nil
	EnsureDB()  -- clean stale default/applied references
end

function API.RenameProfile(oldName, newName)
	newName = type(newName) == "string" and string.trim(newName) or ""
	if newName == "" or newName == oldName then return end
	local db = EnsureDB()
	if not db.profiles[oldName] or db.profiles[newName] then return end
	db.profiles[newName] = db.profiles[oldName]
	db.profiles[oldName] = nil
	if db.globalDefault == oldName then db.globalDefault = newName end
	for cls, name in pairs(db.classDefaults) do
		if name == oldName then db.classDefaults[cls] = newName end
	end
	for role, name in pairs(db.roleDefaults) do
		if name == oldName then db.roleDefaults[role] = newName end
	end
	if ChungusCharDB.applied == oldName then ChungusCharDB.applied = newName end
end

function API.GetProfiles()
	local db = EnsureDB()
	local names = {}
	for name in pairs(db.profiles) do tinsert(names, name) end
	table.sort(names)
	return names
end

function API.GetProfile(name)
	return EnsureDB().profiles[name]
end

-- ------------------------------------------------------------------
-- Defaults and resolution.
-- ------------------------------------------------------------------
-- tier: "global" | "class" | "role"
function API.SetDefaultTier(tier, profileName)
	local db = EnsureDB()
	if not db.profiles[profileName] then return end
	if tier == "global" then
		db.globalDefault = profileName
	elseif tier == "class" then
		local cls = GetClassFile()
		if cls then db.classDefaults[cls] = profileName end
	elseif tier == "role" then
		local role = ChungusCharDB.role
		if role then db.roleDefaults[role] = profileName end
	end
end

function API.GetDefaultTier(tier)
	local db = EnsureDB()
	if tier == "global" then return db.globalDefault end
	if tier == "class" then
		local cls = GetClassFile()
		return cls and db.classDefaults[cls] or nil
	end
	if tier == "role" then
		local role = ChungusCharDB.role
		return role and db.roleDefaults[role] or nil
	end
	return nil
end

-- What "Auto" resolves to right now, and the chain used (for status display).
function API.GetResolvedProfile()
	local db = EnsureDB()
	if ChungusCharDB.applied and db.profiles[ChungusCharDB.applied] then
		return ChungusCharDB.applied, "applied"
	end
	local via = API.GetDefaultTier("class")
	if via then return via, "class" end
	via = API.GetDefaultTier("role")
	if via then return via, "role" end
	via = API.GetDefaultTier("global")
	if via then return via, "global" end
	return nil, nil
end

-- ------------------------------------------------------------------
-- Snapshots (tier 3): capture / restore another addon's saved-variable table.
-- ------------------------------------------------------------------
function API.CaptureSnapshot(profileName, savedvar)
	local profile = EnsureDB().profiles[profileName]
	if not profile then return end
	local v = G[savedvar]
	if type(v) ~= "table" then
		print("[Chungus] Global '" .. tostring(savedvar) .. "' is not a table - nothing to snapshot.")
		return
	end
	profile.snapshots = profile.snapshots or {}
	profile.snapshots[savedvar] = DeepCopy(v)
	print("[Chungus] Snapshot of '" .. savedvar .. "' captured into profile '" .. profileName .. "'.")
end

local function RestoreSnapshot(profileName, savedvar)
	local profile = EnsureDB().profiles[profileName]
	if not profile or not profile.snapshots then return end
	local snap = profile.snapshots[savedvar]
	if type(snap) ~= "table" then
		print("[Chungus] No snapshot of '" .. tostring(savedvar) .. "' in profile '" .. profileName .. "' (capture it first).")
		return
	end
	local copy = DeepCopy(snap)
	local target = G[savedvar]
	if type(target) ~= "table" then
		G[savedvar] = copy
	else
		WipeTable(target)
		for k, v in pairs(copy) do target[k] = v end
	end
	print("[Chungus] Restored snapshot of '" .. savedvar .. "' - run /reload for it to take full effect.")
end

-- ------------------------------------------------------------------
-- Running a single action (shared with the Setup module).
-- ------------------------------------------------------------------
function API.RunAction(profileName, action)
	local profile = EnsureDB().profiles[profileName]
	if not profile then return end
	local kind = action.kind or "cmd"
	if kind == "cmd" then
		if action.command and action.command ~= "" then
			print("[Chungus] Run: " .. action.command)
			API.RunCommand(action.command)
		end
	elseif kind == "api" then
		-- Arguments: action.args is the canonical list. "$profile" anywhere in
		-- it (and an empty first argument) means "the profile being applied".
		-- action.profile is the legacy single-argument form.
		local args = {}
		if type(action.args) == "table" then
			for i, a in ipairs(action.args) do args[i] = tostring(a) end
		end
		if #args == 0 and type(action.profile) == "string" and action.profile ~= "" then
			args[1] = action.profile
		end
		for i = 1, #args do
			if args[i] == "$profile" then args[i] = profileName end
		end
		local target = args[1]
		if target == nil or target == "" then target = profileName end
		local attempted = false
		-- 1) Explicit member call, possibly a dotted path ("API.Foo").
		if action.member and action.member ~= "" then
			attempted = true
			local parent, fn = API.ResolveMember(action.addon, action.member)
			if type(fn) == "function" then
				-- Colon-style methods take self implicitly; dotted functions
				-- (Addon.API.Foo(...)) must not receive the table.
				local desc = API.DescribeFunction(action.addon, action.member)
				local callArgs = {}
				for i = 1, #args do callArgs[i] = args[i] end
				-- No explicit argument typed: hand it the profile name only when
				-- the function actually declares a parameter.
				if #callArgs == 0 and desc.params >= 1 then callArgs[1] = target end
				local ok, r1, r2, r3
				if desc.colon then
					ok, r1, r2, r3 = pcall(fn, parent, unpack(callArgs))
				else
					ok, r1, r2, r3 = pcall(fn, unpack(callArgs))
				end
				local shown = {}
				for i = 1, #callArgs do shown[i] = tostring(callArgs[i]) end
				local callText = "(" .. table.concat(shown, ", ") .. ")"
				if ok then
					local out = {}
					for _, v in ipairs({ r1, r2, r3 }) do
						if v ~= nil then tinsert(out, tostring(v)) end
					end
					local result = #out > 0 and table.concat(out, ", ") or "no return values"
					if #result > 300 then result = string.sub(result, 1, 300) .. "..." end
					print("[Chungus] " .. tostring(action.addon) .. ":" .. tostring(action.member)
						.. callText .. " -> " .. result)
				else
					print("[Chungus] API call failed (" .. tostring(action.addon) .. ":" .. tostring(action.member) .. "): " .. tostring(r1))
				end
			else
				print("[Chungus] " .. tostring(action.addon) .. " does not expose function '"
					.. tostring(action.member) .. "' (open the function dropdown to see what it does expose).")
			end
		end
		-- 2) Registered handler (curated, or auto-registered per addon).
		if not attempted then
			local handler = Addon.Handlers[action.addon]
			if handler then
				local ok, result = pcall(handler, target)
				if ok then
					local applied = tostring(result)
					if applied == "reload" then
						print("[Chungus] API apply: " .. tostring(action.addon)
							.. " -> '" .. tostring(target) .. "' (takes effect on next /reload)")
					elseif applied == "already active" then
						print("[Chungus] " .. tostring(action.addon) .. " is already on '" .. tostring(target) .. "'")
					else
						print("[Chungus] API apply: " .. tostring(action.addon) .. " -> '" .. tostring(target) .. "'")
					end
				else
					print("[Chungus] API error (" .. tostring(action.addon) .. "): " .. tostring(result))
				end
			elseif action.command and action.command ~= "" then
				print("[Chungus] No API handler for '" .. tostring(action.addon) .. "' - running command instead.")
				API.RunCommand(action.command)
			elseif not API.GetAddonProfiles(action.addon) then
				print("[Chungus] " .. tostring(action.addon) .. " has no profile API - pick a function"
					.. " from the row's function dropdown (or use a CMD/SNAP row).")
			else
				-- Profile-capable but the handler was registered before the
				-- addon loaded: switch directly.
				local ok, result = pcall(API.SetAddonProfile, action.addon, target)
				if ok then
					print("[Chungus] API apply: " .. tostring(action.addon) .. " -> '" .. tostring(target) .. "'")
				else
					print("[Chungus] API error (" .. tostring(action.addon) .. "): " .. tostring(result))
				end
			end
		end
	elseif kind == "snap" then
		RestoreSnapshot(profileName, action.savedvar)
	end
end

-- ------------------------------------------------------------------
-- Apply. Sets the per-character applied profile, then (optionally) runs the
-- onApply of every module checked in profile.modules, staggered.
-- ApplyProfile(nil) applies whatever Auto resolves to.
-- ------------------------------------------------------------------
function Addon.RunProfileModules(profileName, startDelay)
	local profile = EnsureDB().profiles[profileName]
	if not profile then return end
	local delay = startDelay or 0.5
	for _, tab in ipairs(Addon.Tabs) do
		if tab.module and tab.module.onApply then
			if profile.modules[tab.key] == nil then profile.modules[tab.key] = true end
			if profile.modules[tab.key] then
				local module = tab.module
				local key = tab.key
				Addon.RunAfter(delay, function()
					local ok, err = pcall(module.onApply, profileName)
					if not ok then print("[Chungus] module '" .. key .. "' apply error: " .. tostring(err)) end
				end)
				delay = delay + 0.5
			end
		end
	end
end

function API.ApplyProfile(name, opts)
	opts = opts or {}
	local db = EnsureDB()
	if not name then name = API.GetResolvedProfile() end
	if not name or not db.profiles[name] then
		print("[Chungus] Nothing to apply - create a profile first.")
		return nil
	end
	ChungusCharDB.applied = name
	print("[Chungus] Applied '" .. name .. "' for " .. tostring(UnitName("player") or "?") .. ".")
	if opts.run ~= false then
		Addon.RunProfileModules(name, opts.delay or 0.5)
	end
	if Addon.RefreshUI then Addon.RefreshUI() end
	return name
end

function API.ClearApplied()
	ChungusCharDB.applied = nil
	print("[Chungus] Cleared the applied profile for this character.")
	if Addon.RefreshUI then Addon.RefreshUI() end
end

-- ------------------------------------------------------------------
-- Startup: resolved profile runs once at login IF it has "run at login",
-- and only for the modules checked in that profile.
-- ------------------------------------------------------------------
local coreEvents = CreateFrame("FRAME")
coreEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
coreEvents:SetScript("OnEvent", function()
	local db = EnsureDB()
	-- All addons' AceDB objects exist by now; turn them into API handlers so
	-- Setup rows naming e.g. "Bartender4" just work. Force a rescan so
	-- load-on-demand addons that appeared after the first scan are included.
	API.RegisterAceHandlers(true)
	local name, via = API.GetResolvedProfile()
	if name and db.profiles[name] and db.profiles[name].onLogin then
		print("[Chungus] Startup: applying '" .. name .. "' (" .. tostring(via) .. " default).")
		Addon.RunProfileModules(name, 4)
	end
end)

-- ------------------------------------------------------------------
-- Slash commands. /chungus opens the window (also /chungusp alias).
-- ------------------------------------------------------------------
SLASH_ChungusMain1 = "/chungus"
SLASH_ChungusMain2 = "/chungusp"
SLASH_ChungusMain3 = "/chungus_profile"
SlashCmdList.ChungusMain = function()
	if Addon.ToggleWindow then
		Addon.ToggleWindow()
	else
		print("[Chungus] UI did not load. Enable error display with /console scriptErrors 1, then /reload.")
	end
end

SLASH_ChungusDebug1 = "/chungusdebug"
SlashCmdList.ChungusDebug = function()
	local db = EnsureDB()
	local name, via = API.GetResolvedProfile()
	print("[Chungus] class=" .. tostring(GetClassFile()) .. " role=" .. tostring(ChungusCharDB.role)
		.. " applied=" .. tostring(ChungusCharDB.applied)
		.. " resolved=" .. tostring(name) .. "(" .. tostring(via) .. ")"
		.. " globalDefault=" .. tostring(db.globalDefault))
	local profiles = API.GetProfiles()
	print("[Chungus] profiles (" .. #profiles .. "): " .. table.concat(profiles, ", "))
	local tabs = {}
	for _, t in ipairs(Addon.Tabs) do tinsert(tabs, t.key .. "(" .. tostring(t.module ~= nil) .. ")") end
	print("[Chungus] registered tabs: " .. table.concat(tabs, ", "))
	local addons = API.GetInstalledAddons()
	local loaded = 0
	for _, a in ipairs(addons) do if a.loaded then loaded = loaded + 1 end end
	print("[Chungus] addons installed=" .. #addons .. " loaded=" .. loaded
		.. " slashCommands=" .. #API.GetSlashCommands())
	local ace = API.GetAceDatabases(true)
	local aceParts = {}
	for _, e in ipairs(ace) do
		tinsert(aceParts, e.label .. "(" .. tostring(e.current or "?") .. ")")
	end
	print("[Chungus] AceDB (" .. #ace .. "): " .. table.concat(aceParts, ", "))
	local targets = API.GetProfileTargets(true, true)
	local parts = {}
	for _, t in ipairs(targets) do
		tinsert(parts, t.label .. "[" .. t.source .. "](" .. tostring(t.current or "?") .. ")")
	end
	print("[Chungus] profile targets (" .. #targets .. "): " .. table.concat(parts, ", "))

	-- Why an addon is not switchable: only the interesting ones (it declares
	-- saved variables, so it *could* hold profiles, but nothing was found).
	local known = {}
	for _, t in ipairs(targets) do known[t.key] = true end
	local misses = {}
	for _, a in ipairs(addons) do
		if a.loaded and not known[a.name]
			and string.sub(a.name, 1, 7) ~= "Chungus" then
			local sv = API.DescribeSavedvarDetection(a.name)
			if sv then tinsert(misses, a.name .. ": " .. sv) end
		end
	end
	if #misses > 0 then
		print("[Chungus] not switchable (" .. #misses .. "): " .. table.concat(misses, "; "))
	end
end

print("[Chungus] Core loaded. /chungus opens the profile manager, /chungusdebug prints diagnostics.")
