local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Build Menu 2.0",
		desc = "A translucent four-category construction and factory purchase menu with rotating 3D unit previews and categorized tabs. (v2.0 by reforged25-source)",
		author = "reforged25-source / Codex",
		version = "2.0",
		date = "2026 (v2.0)",
		license = "GNU GPL, v2 or later",
		layer = -100,
		enabled = true,
		handler = true,
	}
end

local spGetViewGeometry = Spring.GetViewGeometry
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spGetFactoryCommands = Spring.GetFactoryCommands
local spGetFullBuildQueue = Spring.GetFullBuildQueue
local spGetActiveCmdDescs = Spring.GetActiveCmdDescs
local spGetCmdDescIndex = Spring.GetCmdDescIndex
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamUnits = Spring.GetTeamUnits
local spSetActiveCommand = Spring.SetActiveCommand
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMouseState = Spring.GetMouseState
local spGetModKeyState = Spring.GetModKeyState
local spGetUnitHealth = Spring.GetUnitHealth
local spGetGameSeconds = Spring.GetGameSeconds
local spGetConfigFloat = Spring.GetConfigFloat
local spGetGameFrame = Spring.GetGameFrame
local spSelectUnitArray = Spring.SelectUnitArray

local glColor = gl.Color
local glRect = gl.Rect
local glTexture = gl.Texture
local glTexRect = gl.TexRect

local abs = math.abs
local ceil = math.ceil
local floor = math.floor
local max = math.max
local min = math.min
local sin = math.sin
local cos = math.cos
local pi = math.pi
local format = string.format
local lower = string.lower
local upper = string.upper

local vsx, vsy = 1, 1
local uiScale = 1
local lastSysScale = -1

local function getSystemUIScale()
	local sysScale = 1.0
	if spGetConfigFloat then
		sysScale = tonumber(spGetConfigFloat("ui_scale", 1) or 1.0) or 1.0
	end
	return sysScale
end

local function updateUIScale()
	vsx, vsy = spGetViewGeometry()
	local sysScale = getSystemUIScale()
	local resScale = math.max(0.55, math.min(1.15, (0.70 + (vsx * vsy / 8000000)) * 0.82))
	uiScale = math.max(0.45, math.min(1.60, sysScale * resScale))
end

local buildmenuBridge = {}

local function getUnitBuildOrder()
	if not buildmenuBridge.unitsConfig and VFS and VFS.Include then
		local ok, res = pcall(VFS.Include, "luaui/configs/unit_buildmenu_config.lua")
		if ok and res then buildmenuBridge.unitsConfig = res end
	end
	if buildmenuBridge.unitsConfig and buildmenuBridge.unitsConfig.unitOrder and #buildmenuBridge.unitsConfig.unitOrder > 0 then
		return buildmenuBridge.unitsConfig.unitOrder
	end
	if not buildmenuBridge.fallbackOrder then
		local fb = {}
		if UnitDefs then
			for id in pairs(UnitDefs) do fb[#fb + 1] = id end
			table.sort(fb)
		end
		buildmenuBridge.fallbackOrder = fb
	end
	return buildmenuBridge.fallbackOrder or {}
end

local function getUnitGroups()
	if not buildmenuBridge.unitsConfig and VFS and VFS.Include then
		local ok, res = pcall(VFS.Include, "luaui/configs/unit_buildmenu_config.lua")
		if ok and res then buildmenuBridge.unitsConfig = res end
	end
	local folder = "LuaUI/Images/groupicons/"
	local groupIcons = {
		energy = folder .. "energy.png",
		metal = folder .. "metal.png",
		builder = folder .. "builder.png",
		buildert2 = folder .. "buildert2.png",
		buildert3 = folder .. "buildert3.png",
		buildert4 = folder .. "buildert4.png",
		util = folder .. "util.png",
		weapon = folder .. "weapon.png",
		explo = folder .. "weaponexplo.png",
		weaponaa = folder .. "weaponaa.png",
		weaponsub = folder .. "weaponsub.png",
		aa = folder .. "aa.png",
		emp = folder .. "emp.png",
		sub = folder .. "sub.png",
		nuke = folder .. "nuke.png",
		antinuke = folder .. "antinuke.png",
	}
	return groupIcons, (buildmenuBridge.unitsConfig and buildmenuBridge.unitsConfig.unitGroup) or {}
end

local function installBuildmenuBridge()
	WG = WG or {}
	WG.buildmenu = WG.buildmenu or {}
	WG.buildmenu.getGroups = getUnitGroups
	WG.buildmenu.getOrder = getUnitBuildOrder
	WG.buildmenu.getAlwaysShow = function() return false end
	WG.buildmenu.setAlwaysShow = function() end
	WG.buildmenu.getBottomPosition = function() return false end
	WG.buildmenu.setBottomPosition = function() end
	WG.buildmenu.getSize = function() return 0, 0 end
	WG.buildmenu.getIsShowing = function() return false end
	WG.buildmenu.getShowPrice = function() return true end
	WG.buildmenu.setShowPrice = function() end
	WG.buildmenu.getShowRadarIcon = function() return true end
	WG.buildmenu.setShowRadarIcon = function() end
	WG.buildmenu.getShowGroupIcon = function() return true end
	WG.buildmenu.setShowGroupIcon = function() end
	WG.buildmenu.reloadBindings = function() end
	WG.buildmenu.setHighlight = function() end
	WG.buildmenu.removeHighlight = function() end
	WG.buildmenu.clearHighlights = function() end
	WG.buildmenu.hasHighlight = function() end
	WG.buildmenu.hoverID = nil
end

installBuildmenuBridge()

local font, smallFont
local dirty = true
local lastRefresh = -1
local activeCategory = "economy"
local visible = false
local cards = {}
local availableByCategory = {}
local tabs = {}
local cardAreas = {}
local suppressedStock = {}
local modelDimensions = {}
local strategicIconBitmaps = {}
local resolvedModelMotion = {}
local modelRotation = 0
local modelActionName = "Idle"
local modelActionBob = 0
local modelActionTilt = 0
local modelActionYaw = 0
local modelActionScale = 1
-- 0 means ALL; 1..4 are the individual tech tiers.
local activeTier = 0
local tierTabs = {}
local factoryMode = false
local factoryCards = {}
local factoryAllCards = {}
local factoryTitle = "Factory"
local factorySourceID
local factorySourceUnitID
local factoryQueueTotal = 0

local etaState = {}
local pendingBuildUnitDefID = nil

local function getMyCommanderUnitID()
	local myTeamID = spGetMyTeamID and spGetMyTeamID()
	local candidateUnits = {}
	if myTeamID and spGetTeamUnits then
		local teamUnits = spGetTeamUnits(myTeamID)
		if teamUnits and #teamUnits > 0 then
			for i = 1, #teamUnits do candidateUnits[#candidateUnits + 1] = teamUnits[i] end
		end
	end
	if #candidateUnits == 0 and Spring.GetLocalTeamID and spGetTeamUnits then
		local localTeamUnits = spGetTeamUnits(Spring.GetLocalTeamID())
		if localTeamUnits and #localTeamUnits > 0 then
			for i = 1, #localTeamUnits do candidateUnits[#candidateUnits + 1] = localTeamUnits[i] end
		end
	end
	if #candidateUnits == 0 and Spring.GetAllUnits then
		local allUnits = Spring.GetAllUnits()
		if allUnits and #allUnits > 0 then
			for i = 1, #allUnits do candidateUnits[#candidateUnits + 1] = allUnits[i] end
		end
	end

	for i = 1, #candidateUnits do
		local uID = candidateUnits[i]
		local uDefID = spGetUnitDefID and spGetUnitDefID(uID)
		local uDef = uDefID and UnitDefs[uDefID]
		if uDef and ((uDef.customParams and uDef.customParams.iscommander) or (uDef.name and (uDef.name:find("com") or uDef.name:find("commander")))) then
			return uID, uDefID
		end
	end
	for i = 1, #candidateUnits do
		local uID = candidateUnits[i]
		local uDefID = spGetUnitDefID and spGetUnitDefID(uID)
		local uDef = uDefID and UnitDefs[uDefID]
		if uDef and (uDef.isFactory or uDef.isBuilder or (uDef.buildOptions and #uDef.buildOptions > 0)) then
			return uID, uDefID
		end
	end
	return nil, nil
end

local lastPregameStartUnit = nil

local function isPregameState()
	local gf = spGetGameFrame and spGetGameFrame() or -1
	local isSpec = Spring.GetSpectatingState and Spring.GetSpectatingState() or false
	return gf <= 0 and not isSpec
end

local function getPlayerFactionCommanderDef()
	local myTeamID = spGetMyTeamID and spGetMyTeamID() or (Spring.GetLocalTeamID and Spring.GetLocalTeamID())
	if myTeamID and Spring.GetTeamRulesParam then
		local startDefID = Spring.GetTeamRulesParam(myTeamID, "startUnit")
		if startDefID and UnitDefs[startDefID] then
			return UnitDefs[startDefID]
		end
	end

	local _, comDefID = getMyCommanderUnitID()
	if comDefID and UnitDefs[comDefID] then
		return UnitDefs[comDefID]
	end

	local sideName = ""
	if myTeamID and Spring.GetTeamRulesParam then
		sideName = tostring(Spring.GetTeamRulesParam(myTeamID, "side") or Spring.GetTeamRulesParam(myTeamID, "faction") or ""):lower()
	end
	if sideName == "" and myTeamID and Spring.GetTeamInfo then
		local _, _, _, _, side = Spring.GetTeamInfo(myTeamID, false)
		if side then sideName = tostring(side):lower() end
	end
	if sideName == "" and Spring.GetPlayerInfo and Spring.GetMyPlayerID then
		local _, _, _, _, side = Spring.GetPlayerInfo(Spring.GetMyPlayerID())
		if side then sideName = tostring(side):lower() end
	end
	if sideName:find("cor") then
		return UnitDefNames and (UnitDefNames["corcom"] or UnitDefNames["cor_commander"] or UnitDefNames["armcom"])
	elseif sideName:find("leg") then
		return UnitDefNames and (UnitDefNames["legcom"] or UnitDefNames["leg_commander"])
	else
		return UnitDefNames and (UnitDefNames["armcom"] or UnitDefNames["arm_commander"] or UnitDefNames["corcom"])
	end
end

local function autoSelectCommanderIfNoneSelected()
	local selected = spGetSelectedUnits and spGetSelectedUnits() or {}
	if #selected == 0 then
		local comID = getMyCommanderUnitID()
		if comID and Spring.ValidUnitID(comID) and spSelectUnitArray then
			spSelectUnitArray({ comID })
			return comID
		end
	end
	return selected[1]
end

local function updateETAState(unitID, buildProgress)
	if not unitID or not buildProgress then return end
	local gs = spGetGameSeconds()
	local state = etaState[unitID]
	if not state then
		state = {
			firstSet = true,
			lastTime = gs,
			lastProg = buildProgress,
			rate = nil,
			timeLeft = nil,
			decaying = false,
			decayTime = nil,
		}
		etaState[unitID] = state
		return
	end

	local dt = gs - state.lastTime
	if dt < 0.20 then return end

	local dp = buildProgress - state.lastProg
	state.lastTime = gs
	state.lastProg = buildProgress

	if dp > 0.0001 then
		local currentRate = dp / dt
		if not state.rate then
			state.rate = currentRate
		else
			state.rate = state.rate * 0.70 + currentRate * 0.30
		end
		local remaining = 1.0 - buildProgress
		if state.rate and state.rate > 0.0001 then
			state.timeLeft = remaining / state.rate
		end
		state.decaying = false
		state.decayTime = nil
	elseif dp <= 0.00001 and buildProgress < 0.999 then
		state.decaying = true
		if not state.decayTime and state.timeLeft then
			state.decayTime = state.timeLeft
		end
	end
end

local function getETAString(unitID)
	if not unitID then return nil end
	local state = etaState[unitID]
	if not state then return nil end
	if state.decaying and state.decayTime then
		return "STALL"
	elseif state.timeLeft then
		local secs = math.max(0, state.timeLeft)
		local m = math.floor(secs / 60)
		local s = math.floor(secs % 60)
		return string.format("%d:%02d", m, s)
	end
	return nil
end
local cardScroll = 0
local visibleRows = 1
local maxCardScroll = 0
local totalRows = 1
local menuX, menuY, menuW, menuH = 0, 0, 0, 0
local dragHandle
local panelOffsetX, panelOffsetY = 0, 0
local panelDragging = false
local hoveredItem = nil
local pinnedCompareItem = nil
local pinnedCompareItemB = nil

local REFRESH_SECONDS = 0.20
local CARD_COLUMNS = 3
local CARD_MAX_ROWS = 3
local FACTORY_COLUMNS = 3
local FACTORY_MAX_ROWS = 3
-- All unit cards share one width so factory and builder menus line up.
local CARD_WIDTH = 195
local CARD_HEIGHT = 162
local FACTORY_CARD_WIDTH = CARD_WIDTH
local FACTORY_CARD_HEIGHT = 170
local CARD_GAP = 8
local CATEGORY_COLUMNS = 4
local SHOW_3D_MODELS = true
local MODEL_ROTATION_SPEED = 4.5 -- degrees per second; slower and smoother rotation
local MODEL_CAMERA_PITCH = 35 -- degrees; top-down view
local MODEL_FRONT_YAW = 0 -- face the camera at the center of the motion
local MODEL_ROTATION_LIMIT = 50 -- degrees to either side of the front
local MODEL_ACTIONS = {
	{name = "Idle",      duration = 4.8, bob = 0.6, sway = 0.5, tilt = 0.35, waveCycles = 1, scalePulse = 0.004},
}
local TEXT_SCALE = 1.80 -- make all menu labels easier to read
local PANEL_LEFT = 0 -- replace the stock build menu at the lower-left
local PANEL_BOTTOM = 200 -- keep the menu lower so it stays clear of the minimap

local CATEGORIES = {
	{key = "economy", label = "Economy", tabLabel = "Economy", hotkey = "Z", color = {0.95, 0.78, 0.18, 1}},
	{key = "combat",  label = "Combat",  tabLabel = "Combat",  hotkey = "X", color = {0.95, 0.32, 0.28, 1}},
	{key = "utility", label = "Utility", tabLabel = "Utility", hotkey = "C", color = {0.55, 0.72, 1.0, 1}},
	{key = "build",   label = "Build",   tabLabel = "Build",   hotkey = "V", color = {0.55, 1.0, 0.65, 1}},
}

-- One translucent glass palette is shared by construction and factory views.
-- The fills are intentionally denser than the original glass pass so bright
-- terrain colours do not wash out the unit names and resource values.
local UI_COLORS = {
	panel = {0.015, 0.025, 0.038, 0.76},
	panelBorder = {0.35, 0.65, 0.85, 0.70},
	header = {0.020, 0.045, 0.070, 0.76},
	card = {0.015, 0.028, 0.042, 0.0},
	cardHover = {0.035, 0.070, 0.100, 0.12},
	cardBorder = {0.35, 0.60, 0.75, 0.65},
	tab = {0.020, 0.038, 0.055, 0.75},
	tabSelected = {0.060, 0.120, 0.165, 0.78},
	accent = {0.42, 0.82, 1.00, 0.92},
	plus = {0.18, 0.66, 0.34, 0.90},
	minus = {0.78, 0.24, 0.20, 0.90},
	disabled = {0.16, 0.18, 0.20, 0.72},
}

local screenMouseX, screenMouseY = -1, -1

local function isInRect(x, y, x1, y1, x2, y2)
	return x and y and x >= x1 and x <= x2 and y >= y1 and y <= y2
end

local function beginPanelDrag(x, y)
	panelDragging = true
	return true
end

local function clampPanelPosition()
	if menuW <= 0 or menuH <= 0 or uiScale <= 0 then return end
	local margin = 6 * uiScale
	local minX = margin
	local minY = margin
	local maxX = max(minX, vsx - menuW - margin)
	local maxY = max(minY, vsy - menuH - margin)
	local currentX = (PANEL_LEFT + panelOffsetX) * uiScale
	local currentY = (PANEL_BOTTOM + panelOffsetY) * uiScale
	local clampedX = min(max(currentX, minX), maxX)
	local clampedY = min(max(currentY, minY), maxY)
	panelOffsetX = clampedX / uiScale - PANEL_LEFT
	panelOffsetY = clampedY / uiScale - PANEL_BOTTOM
end

local function drawDragGrip(x, y, w, h, color)
	-- A small grip in the panel's top padding makes the draggable div obvious.
	glColor(color[1], color[2], color[3], color[4] * 0.72)
	local gripW = 22 * uiScale
	local gripH = 2 * uiScale
	local startX = x + (w - gripW) * 0.5
	for i = 0, 2 do
		glRect(startX + i * 8 * uiScale, y + h * 0.5, startX + i * 8 * uiScale + gripW * 0.18, y + h * 0.5 + gripH)
	end
end

local function drawGlassRect(x1, y1, x2, y2, fill, border, accent)
	glColor(fill[1], fill[2], fill[3], fill[4])
	glRect(x1, y1, x2, y2)
	border = border or UI_COLORS.cardBorder
	glColor(border[1], border[2], border[3], border[4])
	glRect(x1, y1, x2, y1 + 1 * uiScale)
	glRect(x1, y2 - 1 * uiScale, x2, y2)
	glRect(x1, y1, x1 + 1 * uiScale, y2)
	glRect(x2 - 1 * uiScale, y1, x2, y2)
	-- Faint reflection keeps glass panels readable over bright terrain.
	glColor(1, 1, 1, 0.035)
	glRect(x1 + 1 * uiScale, y2 - 3 * uiScale, x2 - 1 * uiScale, y2 - 1 * uiScale)
	if accent then
		glColor(accent[1], accent[2], accent[3], accent[4])
		glRect(x1 + 1 * uiScale, y2 - 3 * uiScale, x2 - 1 * uiScale, y2)
	end
end

local function drawHoverGlow(x1, y1, x2, y2, glowColor)
	glowColor = glowColor or {0.38, 0.88, 1.0, 1.0}
	local r, g, b = glowColor[1], glowColor[2], glowColor[3]

	-- Translucent inner card highlight (soft & faint)
	glColor(r, g, b, 0.05)
	glRect(x1, y1, x2, y2)

	-- Faint outer soft diffusion halo (single subtle layer)
	local o1 = 2.5 * uiScale
	glColor(r, g, b, 0.16)
	glRect(x1 - o1, y1 - o1, x2 + o1, y1)
	glRect(x1 - o1, y2, x2 + o1, y2 + o1)
	glRect(x1 - o1, y1, x1, y2)
	glRect(x2, y1, x2 + o1, y2)

	-- Slim crisp border (1.2px)
	local bw = 1.2 * uiScale
	glColor(r, g, b, 0.65)
	glRect(x1, y1, x2, y1 + bw)
	glRect(x1, y2 - bw, x2, y2)
	glRect(x1, y1, x1 + bw, y2)
	glRect(x2 - bw, y1, x2, y2)

	-- Delicate, slim corner brackets (soft white)
	local cs = 8 * uiScale
	local csw = 1.4 * uiScale
	glColor(1.0, 1.0, 1.0, 0.65)
	-- Top-left
	glRect(x1, y2 - cs, x1 + csw, y2)
	glRect(x1, y2 - csw, x1 + cs, y2)
	-- Top-right
	glRect(x2 - cs, y2 - csw, x2, y2)
	glRect(x2 - csw, y2 - cs, x2, y2)
	-- Bottom-left
	glRect(x1, y1, x1 + cs, y1 + csw)
	glRect(x1, y1, x1 + csw, y1 + cs)
	-- Bottom-right
	glRect(x2 - cs, y1, x2, y1 + csw)
	glRect(x2 - csw, y1, x2, y1 + cs)
end


local function contains(textValue, needle)
	return textValue:find(needle, 1, true) ~= nil
end

local function matchesAny(textValue, patterns)
	for i = 1, #patterns do
		if contains(textValue, patterns[i]) then return true end
	end
	return false
end

-- Role names from the Armada/Cortex/Legion roster reference.  These explicit
-- lists cover support and resource units whose names or weapon slots alone do
-- not reliably reveal their intended tab.
local ROLE_ECONOMY_NAMES = {
	"metal extractor", "overcharged metal extractor", "advanced underwater metal extractor",
	"advanced metal fortifier", "wind turbine", "solar collector", "tidal generator",
	"geothermal powerplant", "offshore geothermal powerplant", "energy converter",
	"naval energy converter", "advanced metal extractor", "naval advanced metal extractor",
	"moho mine", "advanced solar collector", "fusion reactor", "cloakable fusion reactor",
	"naval fusion reactor", "advanced energy converter", "naval advanced energy converter",
	"advanced geothermal powerplant", "advanced underwater geothermal powerplant",
	"hardened metal storage", "hardened energy storage", "metal storage", "energy storage",
	"naval metal storage", "naval energy storage", "advanced fusion reactor",
}
local ROLE_UTILITY_NAMES = {
	"flea", "jeffy", "smuggler", "compass", "ghost", "butler", "webber", "rover", "groundhog",
	"umbra", "prophet", "beholder", "radar tower", "advanced radar tower", "sonar station",
	"advanced sonar station", "naval radar", "sonar tower", "jammer tower", "advanced jammer", "deceiver",
	"augur", "spectre", "twitcher", "trapper", "graverobber", "transport", "sneaky pete",
	"repair", "resurrect", "nano", "nanoturret", "advanced radar", "advanced sonar", "sonar",
	"radar", "jammer", "pinpointer", "naval pinpointer", "juno", "anti-nuke", "plasma deflector",
	"abductor", "overseer", "commander decoy", "legion commander decoy", "zagreus", "sapper",
	"aeolus", "iapetus", "dionysus", "argus", "tiresias", "euclid", "eidolon", "proteus",
	"hera", "cicero", "pheme", "whisper", "okeanos", "dolus", "erebus", "ichnaea", "soteria",
	"dragon's teeth", "shark's teeth", "fortification wall", "auscultor", "twilight", "castro",
	"nyx", "veil", "shroud", "tracer", "nemesis", "decoy fusion reactor", "prude", "paralyzer",
	"citadel", "prevailer", "aegis", "keeper",
}
local ROLE_COMBAT_NAMES = {
	-- Armada / Cortex / Legion (T1-T3).  Cortex's roster is kept verbatim;
	-- the duplicated Cortex Behemoth entry is treated as Combat (its primary
	-- role) so one unit does not appear twice in the four-tab menu.
	"pawn", "rocketeer", "tick", "trasher", "blitz", "janus", "stout", "whistler",
	"warden", "hound", "welder", "recluse", "skater", "dolphin", "lurker", "piranha",
	"destroyer", "torpedo bomber", "fighter", "bomber", "gunship", "tumbleweed", "light mine",
	"medium mine", "heavy mine", "sentry", "nettle", "naval nettle", "harpoon", "beamer",
	"anemone", "dragon's claw", "dragon's jaw", "ferret", "rhapsis", "sprinter", "platypus", "archangel", "gunslinger",
	"sharpshooter", "fatboy", "marauder", "vanguard", "bulldog", "jaguar", "panther", "starlight",
	"penetrator", "liche", "phoenix", "brawler", "advanced fighter", "advanced bomber", "cruiser",
	"battleship", "submarine", "amphibious tank", "overwatch", "manta", "chainsaw", "gauntlet",
	"pit bull", "arbalest", "naval arbalest", "moray", "gorgon", "mercury", "rattlesnake",
	"pulsar", "basilica", "armageddon", "cerberus", "bulwark", "razorback", "titan", "bantha", "thor", "epoch", "ragnarok",
	-- Cortex (T1-T3)
	"grunt", "aggravator", "thug", "rascal", "incisor", "pounder", "brute", "supporter",
	"herring", "bedbug", "dragon's maw", "lotus", "defender", "torpedo launcher", "fiend", "duck",
	"sheldon", "termite", "sumo", "arbiter", "manticore", "skuttle", "commando", "mammoth", "crocodile",
	"tiger", "goliath", "reaper", "banisher", "negotiator", "shuriken", "raptor", "attack submarine",
	"flamethrower turret", "heavy laser tower", "flak cannon", "heavy plasma cannon", "tachyon accelerator",
	"nuclear missile launcher", "slingshot", "thistle", "guard", "urchin", "twin guard", "exploiter",
	"jellyfish", "sam", "coral", "eradicator", "agitator", "scorpion", "naval birdshot", "birdshot",
	"lamprey", "catalyst", "devastator", "screamer", "advanced exploiter", "persecutor", "basilisk",
	"apocalypse", "calamity", "catapult", "shiva", "karganeth", "demon", "juggernaut", "behemoth",
	-- Legion (T1-T3)
	"goblin", "satyr", "toxotai", "phobos", "ballista", "karkinos", "snapper", "wheelie", "alaris",
	"helios", "cetus", "lance", "legion drone", "noctua", "martyr", "astrapios", "mosquito", "hippocampus",
	"ketea", "argonaut", "pharos", "bramble", "polybolos", "stheno", "euryale", "infestor", "hoplite",
	"phalanx", "belcher", "telchine", "thanatos", "aquilon", "arquebus", "incinerator", "gladiator",
	"prometheus", "medusa", "inferno", "keres", "ladon", "pyrphoros", "hecatoncheir", "enyo", "venator",
	"ajax", "harbinger", "syracusia", "octeres", "leocampus", "naval hive", "hive", "cacophony", "gelasma",
	"amputator", "lupara", "chimera", "pluto", "fulmen", "delphinus", "perdition", "ionia", "xyston",
	"eviscerator", "javelin", "myrmidon", "praetorian", "astraeus", "sol invictus", "rampart", "bastion",
	"olympus", "supernova", "starfall",
}
local ROLE_BUILD_NAMES = {
	"armada commander", "cortex commander", "legion commander", "construction bot", "construction vehicle",
	"construction aircraft", "construction ship", "construction hovercraft", "construction seaplane",
	"construction aircraft", "construction seaplane", "t3 constructor", "advanced construction bot",
	"advanced construction vehicle", "advanced construction aircraft", "advanced construction ship",
	"artifex", "legion construction bot", "legion construction vehicle", "bot lab", "vehicle plant",
	"aircraft plant", "shipyard", "hovercraft platform", "seaplane platform", "offshore seaplane platform",
	"advanced bot lab", "advanced vehicle plant", "advanced aircraft plant", "advanced shipyard",
}

local function drawText(value, x, y, size, color, options)
	local f = (size <= 11 and smallFont) or font
	size = size * TEXT_SCALE
	local drawn = false
	if f then
		local ok = pcall(function()
			f:Begin()
			f:SetTextColor(color[1], color[2], color[3], color[4] or 1)
			f:Print(value, x, y, size, options or "o")
			f:End()
		end)
		if ok then
			drawn = true
		else
			if WG.fonts then
				font = WG.fonts.getFont(2, 1.0)
				smallFont = WG.fonts.getFont(2, 0.85)
			else
				font, smallFont = nil, nil
			end
		end
	end
	if not drawn then
		glColor(color[1], color[2], color[3], color[4] or 1)
		gl.Text(value, x, y, size, options or "o")
	end
end

local function getTextPixelWidth(textValue, size)
	if not textValue or textValue == "" then return 0 end
	local f = (size <= 11 and smallFont) or font
	if f and f.GetTextWidth then
		local ok, w = pcall(function() return f:GetTextWidth(textValue) end)
		if ok and w and w > 0 then
			return w * (size * TEXT_SCALE)
		end
	end
	return #textValue * (size * TEXT_SCALE) * 0.65
end

local function fitTitleToWidth(value, maxWidth, size)
	value = value or ""
	if value == "" or maxWidth <= 0 then return value end
	if getTextPixelWidth(value, size) <= maxWidth then return value end
	local suffix = ".."
	local length = #value
	while length > 1 and getTextPixelWidth(value:sub(1, length) .. suffix, size) > maxWidth do
		length = length - 1
	end
	return value:sub(1, length) .. suffix
end

local function formatCost(value)
	value = value or 0
	if abs(value) >= 1000 then return format("%.1fk", value / 1000) end
	if abs(value) >= 100 then return format("%.0f", value) end
	return format("%.0f", value)
end

local function getModelDimensions(unitDefID)
	local cached = modelDimensions[unitDefID]
	if cached then return cached end
	local def = UnitDefs[unitDefID]
	local dimensions = def and def.dimensions
	if not dimensions and Spring.GetUnitDefDimensions then
		dimensions = Spring.GetUnitDefDimensions(unitDefID)
	end
	if not dimensions then return nil end
	modelDimensions[unitDefID] = dimensions
	return dimensions
end

local function resolveModelMotion()
	local motion = resolvedModelMotion
	if type(motion) ~= "table" then
		motion = {}
		resolvedModelMotion = motion
	end
	motion.name = modelActionName
	motion.bob = tonumber(modelActionBob) or 0
	motion.tilt = tonumber(modelActionTilt) or 0
	motion.yaw = tonumber(modelActionYaw) or 0
	-- No firing/recoil animation is used.
	motion.recoil = 0
	motion.scale = tonumber(modelActionScale) or 1
	return motion
end

local function refreshStrategicIcons()
	strategicIconBitmaps = {}
	if not VFS or not VFS.Include then return end
	local ok, iconDefs = pcall(VFS.Include, "gamedata/icontypes.lua")
	if not ok or type(iconDefs) ~= "table" then return end
	for unitDefID, def in pairs(UnitDefs) do
		local iconType = def.iconType
		local iconDef = iconType and iconDefs[iconType]
		if iconDef and iconDef.bitmap then
			strategicIconBitmaps[unitDefID] = iconDef.bitmap
		end
	end
end

local function drawStrategicIcon(x, y, size, item)
	local bitmap = strategicIconBitmaps[item.unitDefID]
	if bitmap then
		local tint = item.disabled and 0.42 or 1
		glColor(tint, tint, tint, 1)
		glTexture(":l:" .. bitmap)
		glTexRect(x, y, x + size, y + size)
		glTexture(false)
		return
	end

	-- Fallback marker for a unit definition that has no bitmap entry.  This
	-- keeps the strategic role visible even in faction/mod content without a
	-- custom icon type.
	local def = UnitDefs[item.unitDefID]
	local iconType = def and def.iconType
	if iconType and iconType ~= "" then
		glColor(0.10, 0.12, 0.15, 0.92)
		glRect(x, y, x + size, y + size)
		drawText(upper(iconType:sub(1, 1)), x + size * 0.5, y + size * 0.5, 9 * uiScale, {1, 1, 1, 1}, "voco")
	end
end

local function drawUnitModel(x, y, w, h, unitDefID, motion)
	if not SHOW_3D_MODELS or not gl.UnitShape then return false end
	-- A partially initialized action state must never break DrawScreen or leave
	-- the OpenGL matrix stack unbalanced.  This also covers widget reloads
	-- while a card is being rebuilt.
	motion = (type(motion) == "table" and motion) or resolveModelMotion()
	local motionBob = tonumber(motion.bob) or 0
	local motionRecoil = tonumber(motion.recoil) or 0
	local motionYaw = tonumber(motion.yaw) or 0
	local motionTilt = tonumber(motion.tilt) or 0
	local motionScale = tonumber(motion.scale) or 1
	local dimensions = getModelDimensions(unitDefID)
	if not dimensions then return false end

	local xSize = dimensions.maxx - dimensions.minx
	local ySize = dimensions.maxy - dimensions.miny
	local zSize = dimensions.maxz - dimensions.minz
	local horizontalSize = max(xSize, zSize)
	if horizontalSize <= 0 or ySize <= 0 then return false end

	local modelAspect = horizontalSize / ySize
	local viewAspect = w / h
	local scale
	if modelAspect > viewAspect then
		scale = w / horizontalSize
	else
		scale = h / ySize
	end
	scale = scale * 0.78

	glTexture(false)
	gl.DepthTest(true)
	gl.DepthMask(true)
	gl.Lighting(true)
	gl.Blending(false)
	gl.Material({
		ambient = {0.20, 0.20, 0.20, 1.0},
		diffuse = {1.0, 1.0, 1.0, 1.0},
		emission = {0.0, 0.0, 0.0, 1.0},
		specular = {0.20, 0.20, 0.20, 1.0},
		shininess = 16.0,
	})

	gl.PushMatrix()
	gl.Scissor(floor(x), floor(y), max(1, floor(w)), max(1, floor(h)))
	gl.Translate(x + w * 0.5, y + h * 0.48, 0)
	gl.Translate(0, motionBob, -motionRecoil)
	gl.Rotate(MODEL_CAMERA_PITCH, 1, 0, 0)
	gl.Rotate(modelRotation + motionYaw, 0, 1, 0)
	gl.Rotate(motionTilt, 0, 0, 1)
	-- Scale pulses make the firing beats and walking steps readable even when
	-- the engine is only able to draw the model's bind pose.
	gl.Scale(scale * motionScale, scale * motionScale, scale * motionScale)
	gl.Translate(
		-0.5 * (dimensions.maxx + dimensions.minx),
		-0.5 * (dimensions.maxy + dimensions.miny),
		-0.5 * (dimensions.maxz + dimensions.minz)
	)
	gl.UnitShape(unitDefID, spGetMyTeamID and spGetMyTeamID() or 0, false, true, true)
	gl.Scissor(false)
	gl.PopMatrix()

	gl.Blending(true)
	gl.Lighting(false)
	gl.DepthMask(false)
	gl.DepthTest(false)
	return true
end

local function textForDef(def)
	return lower((def.name or "") .. " " .. (def.humanName or "") .. " " .. (def.translatedHumanName or ""))
end

local function categoryForDef(def)
	if not def then return "utility" end

	local name = textForDef(def)
	local customParams = def.customParams or {}

	if def.isFactory or def.isBuilder or (def.buildOptions and #def.buildOptions > 0) then
		return "build"
	end

	-- The supplied Armada/Cortex/Legion roster is authoritative for the
	-- four tabs.  Use it before generic weapon/name heuristics so identical
	-- names across tech levels stay in the intended role.
	if matchesAny(name, ROLE_BUILD_NAMES) then return "build" end
	if matchesAny(name, ROLE_ECONOMY_NAMES) then return "economy" end
	if matchesAny(name, ROLE_UTILITY_NAMES) then return "utility" end
	if matchesAny(name, ROLE_COMBAT_NAMES) then return "combat" end

	-- Extractors default to Utility even though the engine reports their metal
	-- income through metalMake; named Economy roster entries were handled above.
	local isExtractor = customParams.metal_extractor or (def.extractsMetal and def.extractsMetal > 0)
		or contains(name, "extractor")
	-- Explicit category overrides requested for these unit names.
	if contains(name, "beholder") or contains(name, "juno") then
		return "utility"
	end
	if contains(name, "pulsar") then
		return "combat"
	end
	if contains(name, "citadel") or contains(name, "tracer")
		or contains(name, "pinpointer") or contains(name, "fortification") or contains(name, "keeper") then
		return "utility"
	end
	if isExtractor then return "utility" end

	-- BAR unit metadata is more reliable than localized names when present.
	local unitGroup = lower(tostring(customParams.unitgroup or customParams.unitGroup or ""))
	if unitGroup == "metal" or unitGroup == "energy" or unitGroup == "economy" then
		return "economy"
	elseif unitGroup == "combat" or unitGroup == "defense" or unitGroup == "defence" then
		return "combat"
	elseif unitGroup == "utility" or unitGroup == "support" or unitGroup == "intel" then
		return "utility"
	end

	-- Prefer actual weapon data over name matching. This fixes combat units
	-- whose T2 names happen to contain words such as energy or metal.
	local hasWeapons = (def.weapons and #def.weapons > 0)
		or (tonumber(def.weaponCount) or 0) > 0
		or def.canAttack == true
		or (tonumber(def.maxWeaponRange) or 0) > 0
	local combatName = contains(name, "anti-air") or contains(name, "antiair") or contains(name, "anti air")
		or contains(name, "air defense") or contains(name, "flak") or contains(name, "sam")
		or contains(name, "artillery") or contains(name, "missile") or contains(name, "rocket")
		or contains(name, "nuke") or contains(name, "juno") or contains(name, "launcher")
		or contains(name, "howitzer") or contains(name, "mortar") or contains(name, "cruise")
		or contains(name, "shield") or contains(name, "wall") or contains(name, "barrier")
		or contains(name, "fortification") or contains(name, "experimental")
		or contains(name, "strategic") or contains(name, "superweapon")
		or contains(name, "turret") or contains(name, "defense") or contains(name, "defence")
		or contains(name, "emplacement") or contains(name, "gun")
	if combatName then
		return "combat"
	end

	-- Resource production/storage wins over generic shield/repulsor weapon
	-- slots on economy buildings such as geothermal and fusion structures.
	local makesOrStoresResources = (def.energyMake and def.energyMake > 0)
		or (def.metalMake and def.metalMake > 0)
		or (def.metalStorage and def.metalStorage > 0)
		or (def.energyStorage and def.energyStorage > 0)
	if makesOrStoresResources then
		return "economy"
	end

	-- An armed unit with no resource role belongs in Combat, even if its name
	-- contains an economy word such as energy or metal.
	if hasWeapons then return "combat" end

	if contains(name, "metal") or contains(name, "energy")
		or contains(name, "solar") or contains(name, "wind") or contains(name, "tidal")
		or contains(name, "fusion") or contains(name, "storage") or contains(name, "converter") then
		return "economy"
	end

	if contains(name, "radar") or contains(name, "sonar")
		or contains(name, "jammer") or contains(name, "sensor") or contains(name, "nanoturret")
		or contains(name, "nano") or contains(name, "repair") or contains(name, "resurrect")
		or contains(name, "gate") or contains(name, "teleport") or contains(name, "transport")
		or contains(name, "logistic") or contains(name, "special") or contains(name, "beacon")
		or contains(name, "launchpad") or contains(name, "cargo") then
		return "utility"
	end

	return "utility"
end

local UNIT_TIER_OVERRIDES = {
	-- Hovercraft Platforms (Factories) -> T1
	["armhp"]   = 1, -- Hovercraft Platform (Armada) -> T1
	["armfhp"]  = 1, -- Naval Hovercraft Platform (Armada) -> T1
	["corhp"]   = 1, -- Hovercraft Platform (Cortex) -> T1
	["corfhp"]  = 1, -- Naval Hovercraft Platform (Cortex) -> T1
	["leghp"]   = 1, -- Hovercraft Platform (Legion) -> T1
	["legfhp"]  = 1, -- Offshore Hovercraft Platform (Legion) -> T1

	-- Hovercraft Units
	["armsh"]   = 1, -- Seeker (Fast Attack Hovercraft) -> T1
	["corsh"]   = 1, -- Skater (Cortex Fast Attack Hovercraft) -> T1
	["legsh"]   = 1,
	["armmh"]   = 1, -- Possum (Hovercraft Rocket Launcher) -> T1
	["cormh"]   = 1, -- Nettle (Cortex Rocket Hovercraft) -> T1
	["legmh"]   = 1,
	["armch"]   = 1, -- Construction Hovercraft (Tech 1 Constructor) -> T1
	["corch"]   = 1, -- Cortex Construction Hovercraft (Tech 1) -> T1
	["legch"]   = 1,
	["armah"]   = 1, -- Sweeper (Anti-Air Hovercraft) -> T1
	["corah"]   = 1, -- Cortex Anti-Air Hovercraft -> T1
	["legah"]   = 1,
	["armanac"] = 1, -- Crocodile (Hovertank) -> T1
	["corhal"]  = 1, -- Halberd (Cortex Hovertank) -> T1
	["anac"]    = 1,
	["armlun"]  = 3, -- Lunkhead (Heavy Hovertank) -> T3
	["corlun"]  = 3,
}

local function unitTechTier(def)
	if not def then return 1 end
	local unitName = lower(def.name or "")
	if UNIT_TIER_OVERRIDES[unitName] then
		return UNIT_TIER_OVERRIDES[unitName]
	end

	local text = textForDef(def)
	if contains(text, "seeker") or contains(text, "possum") or contains(text, "sweeper") or contains(text, "crocodile")
		or (contains(text, "hovercraft platform") and not contains(text, "advanced"))
		or (contains(text, "construction hover") and not contains(text, "advanced")) then
		return 1
	elseif contains(text, "lunkhead") then
		return 3
	end

	local customParams = def.customParams or {}
	local value = customParams.techlevel or customParams.techLevel or def.techLevel
	local tier = tonumber(value)
	if not tier then
		if contains(text, "t4") or contains(text, "experimental") then tier = 4
		elseif contains(text, "t3") then tier = 3
		elseif contains(text, "t2") then tier = 2
		else tier = 1 end
	end
	return min(4, max(1, ceil(tier)))
end

local function isUnitRestricted(unitDefID, def)
	if not def then return false end

	-- 1. Engine / Gadget blocking flags
	local customParams = def.customParams or {}
	if customParams.modoption_blocked or customParams.modoption_blocked == "true" or customParams.modoption_blocked == 1 or customParams.modoption_blocked == true then
		return true
	end
	if def.maxThisUnit == 0 then
		return true
	end

	-- 2. Team rules param check (api_build_blocking.lua)
	local myTeamID = spGetMyTeamID and spGetMyTeamID() or (Spring.GetLocalTeamID and Spring.GetLocalTeamID())
	if myTeamID and Spring.GetTeamRulesParam then
		local blockedReason = Spring.GetTeamRulesParam(myTeamID, "unitdef_blocked_" .. unitDefID)
		if blockedReason and blockedReason ~= "" then
			return true
		end
	end

	-- 3. Direct ModOptions check
	local mo = Spring.GetModOptions and Spring.GetModOptions()
	if not mo then return false end

	local techLevel = tonumber(customParams.techlevel) or def.techLevel
	if mo.unit_restrictions_notech15 and (techLevel == 1.5 or (techLevel and techLevel > 1 and techLevel < 2)) then return true end
	if mo.unit_restrictions_notech2 and (techLevel == 2 or (techLevel and techLevel >= 2 and techLevel < 3)) then return true end
	if mo.unit_restrictions_notech3 and (techLevel and techLevel >= 3) then return true end

	local inc = tostring(customParams.restrictions_inclusion or "")
	local exc = tostring(customParams.restrictions_exclusion or "")

	if mo.unit_restrictions_noair and not exc:find("_noair_") then
		if (customParams.subfolder and customParams.subfolder:find("Aircraft", 1, true))
			or (customParams.unitgroup == "aa")
			or def.canFly
			or inc:find("_noair_") then
			return true
		end
	end

	if mo.unit_restrictions_nosea and not exc:find("_nosea_") then
		if (def.minWaterDepth and def.minWaterDepth > 0)
			or (def.modCategories and def.modCategories.ship)
			or (def.category and def.category:find("SHIP"))
			or inc:find("_nosea_") then
			return true
		end
	end

	if mo.unit_restrictions_noextractors then
		if (def.extractsMetal and def.extractsMetal > 0) or (tonumber(customParams.metal_extractor or 0) > 0) or def.makesMetal then
			return true
		end
	end

	if mo.unit_restrictions_noconverters then
		if customParams.energyconv_capacity and customParams.energyconv_efficiency then
			return true
		end
	end

	if mo.unit_restrictions_nofusion and inc:find("_nofusion_") then
		return true
	end

	if mo.unit_restrictions_notacnukes and inc:find("_notacnukes_") then
		return true
	end

	if mo.unit_restrictions_nonukes then
		if inc:find("_nonukes_") then return true end
		if def.weapons then
			for _, wt in ipairs(def.weapons) do
				local wd = wt.weaponDef and WeaponDefs and WeaponDefs[wt.weaponDef]
				if wd and (wd.targetable == 1 or (wd.customParams and wd.customParams.targetable == "1")) then
					return true
				end
			end
		end
	end

	if mo.unit_restrictions_noantinuke then
		if inc:find("_noantinuke_") then return true end
		if def.weapons then
			for _, wt in ipairs(def.weapons) do
				local wd = wt.weaponDef and WeaponDefs and WeaponDefs[wt.weaponDef]
				if wd and wd.interceptor == 1 then
					return true
				end
			end
		end
	end

	if mo.unit_restrictions_nolrpc and inc:find("_nolrpc_") then
		return true
	end

	if mo.unit_restrictions_noendgamelrpc and inc:find("_noendgamelrpc_") then
		return true
	end

	return false
end

local suppressedStock = {}

local function disableStockBuildWidgets()
	if not widgetHandler or not widgetHandler.knownWidgets then return end
	local myName = (widget.GetInfo and widget:GetInfo().name) or "Build Menu 2.0"
	local myCompactName = lower(tostring(myName)):gsub("[%s_%-%.]", "")
	local didDisable = false
	for name, known in pairs(widgetHandler.knownWidgets) do
		local displayName = (known and known.name) or name
		local compactName = lower(tostring(displayName)):gsub("[%s_%-%.]", "")
		local isThisWidget = (name == myName)
			or (displayName == myName)
			or (known and (known.name == myName or known.widget == widget))
			or compactName == "custombuildmenu"
			or compactName == myCompactName
			or compactName == "buildmenu20"
			or compactName:find("buildmenu2", 1, true) ~= nil
		local isStockBuildMenu = not isThisWidget and (
			compactName == "gridmenu"
			or compactName == "gridbuildmenu"
			or compactName == "buildmenu"
			or compactName == "buildbar"
			or contains(compactName, "gridmenu")
			or contains(compactName, "buildmenu")
			or contains(compactName, "buildbar")
		)
		if isStockBuildMenu and known.active and not suppressedStock[name] then
			widgetHandler:DisableWidget(name)
			suppressedStock[name] = true
			didDisable = true
		end
	end
	if didDisable then
		installBuildmenuBridge()
	end
end

local function restoreStockBuildWidgets()
	if not widgetHandler then return end
	local myName = (widget.GetInfo and widget:GetInfo().name) or "Build Menu 2.0"
	for name in pairs(suppressedStock) do
		if name ~= myName and widgetHandler.EnableWidget then
			widgetHandler:EnableWidget(name)
		end
	end
	suppressedStock = {}
end

-- Factory build commands are queued as negative unitDefIDs.  Keep the
-- aggregation small and local to the selected factories so the menu can show
-- the actual order count without scanning every factory on the team.
local function collectFactoryQueueCounts(unitID)
	local counts = {}
	local foundQueueEntry = false
	local function addQueueCount(unitDefID, count)
		unitDefID = tonumber(unitDefID)
		count = tonumber(count) or 0
		if unitDefID and count > 0 and UnitDefs[unitDefID] then
			counts[unitDefID] = (counts[unitDefID] or 0) + count
			foundQueueEntry = true
		end
	end
	-- GetFullBuildQueue returns one entry per unit type with its aggregated
	-- count. This is both more accurate and cheaper than walking every command
	-- whenever several identical units are queued.
	if spGetFullBuildQueue then
		local fullQueue = spGetFullBuildQueue(unitID)
		if fullQueue then
			-- Recoil builds have exposed both an array of {defID=count} tables
			-- and a direct defID=count map. Accept both shapes.
			for key, value in pairs(fullQueue) do
				if type(value) == "table" then
					for unitDefID, count in pairs(value) do
						addQueueCount(unitDefID, count)
					end
				else
					addQueueCount(key, value)
				end
			end
			if foundQueueEntry or next(fullQueue) == nil then return counts end
		end
	end
	-- Compatibility fallback for engine versions without GetFullBuildQueue.
	if not spGetFactoryCommands then return counts end
	local commands = spGetFactoryCommands(unitID, -1)
	if not commands then return counts end
	for i = 1, #commands do
		local command = commands[i]
		local commandID = command and tonumber(command.id)
		if commandID and commandID < 0 then
			local unitDefID = -commandID
			if UnitDefs[unitDefID] then
				counts[unitDefID] = (counts[unitDefID] or 0) + 1
			end
		end
	end
	return counts
end

local function selectedFactoryIDs()
	local factories = {}
	local selected = spGetSelectedUnits and spGetSelectedUnits() or {}
	for i = 1, #selected do
		local unitID = selected[i]
		local defID = spGetUnitDefID and spGetUnitDefID(unitID)
		local def = defID and UnitDefs[defID]
		if def and def.isFactory then
			factories[#factories + 1] = unitID
		end
	end
	return factories
end

local function commandIndexForUnitDef(unitDefID)
	local wantedID = -unitDefID
	if spGetCmdDescIndex then
		local commandIndex = spGetCmdDescIndex(wantedID)
		if commandIndex then return commandIndex end
	end
	local activeDescs = spGetActiveCmdDescs and spGetActiveCmdDescs()
	if activeDescs then
		for commandIndex = 1, #activeDescs do
			local command = activeDescs[commandIndex]
			if command and command.id == wantedID then return commandIndex end
		end
	end
	return nil
end

-- Mirror BAR's stock factory menu.  Repeating the native action keeps the
-- queue semantics identical to a normal click while allowing Shift-click to
-- add or remove a batch of 20 items.
local function cancelFactoryQueue(unitDefID, amount)
	amount = max(1, floor(tonumber(amount) or 1))
	local commandIndex = commandIndexForUnitDef(unitDefID)
	local cancelledCount = 0
	if commandIndex and spSetActiveCommand then
		for _ = 1, amount do
			local result = spSetActiveCommand(commandIndex, 3, false, true, false, false, false, false)
			if not result then break end
			cancelledCount = cancelledCount + 1
		end
		if cancelledCount > 0 then
			dirty = true
			return cancelledCount
		end
	end
	if not spGiveOrderToUnit then return 0 end
	for _, factoryID in ipairs(selectedFactoryIDs()) do
		for _ = 1, amount do
			spGiveOrderToUnit(factoryID, -unitDefID, {}, {"right"})
			cancelledCount = cancelledCount + 1
		end
	end
	if cancelledCount > 0 then dirty = true end
	return cancelledCount
end

local function selectedBuildCommands()
	local found = {}
	local order = {}
	local factoryFound = {}
	local factoryOrder = {}
	local factoryQueueCounts = {}
	local factoryActiveBuilding = {}
	local factoryBuildingProgress = {}
	local factoryBuildingUnitIDs = {}
	local factoryQueueOrder = {}
	local seenOrder = {}
	local function addQueueOrder(defID)
		defID = tonumber(defID)
		if defID and defID > 0 and not seenOrder[defID] and UnitDefs[defID] then
			seenOrder[defID] = true
			factoryQueueOrder[#factoryQueueOrder + 1] = defID
		end
	end

	local selected = spGetSelectedUnits and spGetSelectedUnits() or {}
	if #selected == 0 then
		local comID = getMyCommanderUnitID()
		if comID and Spring.ValidUnitID(comID) then
			selected = { comID }
		end
	end

	local selectedFactory = false
	local selectedFactoryTitle
	local selectedFactoryDefID
	local selectedFactoryUnitID
	for i = 1, #selected do
		local unitID = selected[i]
		local selectedDefID = spGetUnitDefID and spGetUnitDefID(unitID)
		local selectedDef = selectedDefID and UnitDefs[selectedDefID]
		local fromFactory = selectedDef and selectedDef.isFactory == true
		if fromFactory then
			selectedFactory = true
			selectedFactoryTitle = selectedFactoryTitle or selectedDef.translatedHumanName or selectedDef.humanName or selectedDef.name
			selectedFactoryDefID = selectedFactoryDefID or selectedDefID
			selectedFactoryUnitID = selectedFactoryUnitID or unitID

			-- Detect currently building unit in factory
			local buildingUnitID = spGetUnitIsBuilding and spGetUnitIsBuilding(unitID)
			if buildingUnitID and Spring.ValidUnitID(buildingUnitID) then
				local bDefID = spGetUnitDefID and spGetUnitDefID(buildingUnitID)
				if bDefID then
					factoryActiveBuilding[bDefID] = true
					if spGetUnitHealth then
						local _, _, _, _, bp = spGetUnitHealth(buildingUnitID)
						factoryBuildingProgress[bDefID] = bp or 0
						updateETAState(buildingUnitID, bp or 0)
					end
					factoryBuildingUnitIDs[bDefID] = buildingUnitID
					addQueueOrder(bDefID)
				end
			end
			if spGetFullBuildQueue then
				local fullQueue = spGetFullBuildQueue(unitID)
				if fullQueue then
					for _, entry in ipairs(fullQueue) do
						if type(entry) == "table" then
							for bDefID, count in pairs(entry) do
								if (tonumber(count) or 0) > 0 then
									addQueueOrder(bDefID)
								end
							end
						elseif type(entry) == "number" and entry > 0 then
							addQueueOrder(entry)
						end
					end
				end
			end
			if spGetFactoryCommands then
				local cmds = spGetFactoryCommands(unitID, -1)
				if cmds then
					for _, cmd in ipairs(cmds) do
						if cmd and cmd.id and cmd.id < 0 then
							addQueueOrder(-cmd.id)
						end
					end
				end
			end
		end
		local sawFactoryQueueParams = false
		local descs = spGetUnitCmdDescs and spGetUnitCmdDescs(unitID)
		local hasAnyCmd = false
		if descs then
			for j = 1, #descs do
				local cmd = descs[j]
				local unitDefID = cmd.id and -cmd.id
				if fromFactory and unitDefID and unitDefID > 0 and UnitDefs[unitDefID]
					and cmd.params and cmd.params[1] ~= nil then
					local queueCount = tonumber(cmd.params[1]) or 0
					if queueCount > 0 then
						factoryQueueCounts[unitDefID] = (factoryQueueCounts[unitDefID] or 0) + queueCount
						sawFactoryQueueParams = true
					end
				end
				local targetFound = fromFactory and factoryFound or found
				if unitDefID and unitDefID > 0 and not targetFound[unitDefID] and UnitDefs[unitDefID] then
					local def = UnitDefs[unitDefID]
					if not cmd.hidden and not isUnitRestricted(unitDefID, def) then
						hasAnyCmd = true
						local item = {
							unitDefID = unitDefID,
							category = categoryForDef(def),
							disabled = cmd.disabled == true,
							name = def.translatedHumanName or def.humanName or def.name or "Unknown",
							metal = def.metalCost or 0,
							energy = def.energyCost or 0,
							metalMake = tonumber(def.metalMake or def.makesMetal) or 0,
							metalUse = tonumber(def.metalUse or def.metalUpkeep) or 0,
							energyMake = tonumber(def.energyMake) or 0,
							energyUse = tonumber(def.energyUse or def.energyUpkeep) or 0,
							metalStorage = tonumber(def.metalStorage) or 0,
							energyStorage = tonumber(def.energyStorage) or 0,
							techTier = unitTechTier(def),
						}
						targetFound[unitDefID] = item
						if fromFactory then
							factoryOrder[#factoryOrder + 1] = unitDefID
						else
							order[#order + 1] = unitDefID
						end
					end
				end
			end
		end

		if not hasAnyCmd and selectedDef and selectedDef.buildOptions and #selectedDef.buildOptions > 0 then
			for _, bDefID in ipairs(selectedDef.buildOptions) do
				local bDef = UnitDefs[bDefID]
				if bDef and not found[bDefID] and not isUnitRestricted(bDefID, bDef) then
					local item = {
						unitDefID = bDefID,
						category = categoryForDef(bDef),
						disabled = false,
						name = bDef.translatedHumanName or bDef.humanName or bDef.name or "Unknown",
						metal = bDef.metalCost or 0,
						energy = bDef.energyCost or 0,
						metalMake = tonumber(bDef.metalMake or bDef.makesMetal) or 0,
						metalUse = tonumber(bDef.metalUse or bDef.metalUpkeep) or 0,
						energyMake = tonumber(bDef.energyMake) or 0,
						energyUse = tonumber(bDef.energyUse or bDef.energyUpkeep) or 0,
						metalStorage = tonumber(bDef.metalStorage) or 0,
						energyStorage = tonumber(bDef.energyStorage) or 0,
						techTier = unitTechTier(bDef),
					}
					found[bDefID] = item
					order[#order + 1] = bDefID
				end
			end
		end

		if fromFactory and not sawFactoryQueueParams then
			local queueCounts = collectFactoryQueueCounts(unitID)
			for unitDefID, count in pairs(queueCounts) do
				factoryQueueCounts[unitDefID] = (factoryQueueCounts[unitDefID] or 0) + count
			end
		end
	end

	local currentSel = spGetSelectedUnits and spGetSelectedUnits() or {}
	if #order == 0 and #factoryOrder == 0 and (#currentSel == 0 or isPregameState()) then
		local comDef = getPlayerFactionCommanderDef()
		if comDef and comDef.buildOptions and #comDef.buildOptions > 0 then
			for _, bDefID in ipairs(comDef.buildOptions) do
				local bDef = UnitDefs[bDefID]
				if bDef and not found[bDefID] and not isUnitRestricted(bDefID, bDef) then
					local item = {
						unitDefID = bDefID,
						category = categoryForDef(bDef),
						disabled = false,
						name = bDef.translatedHumanName or bDef.humanName or bDef.name or "Unknown",
						metal = bDef.metalCost or 0,
						energy = bDef.energyCost or 0,
						metalMake = tonumber(bDef.metalMake or bDef.makesMetal) or 0,
						metalUse = tonumber(bDef.metalUse or bDef.metalUpkeep) or 0,
						energyMake = tonumber(bDef.energyMake) or 0,
						energyUse = tonumber(bDef.energyUse or bDef.energyUpkeep) or 0,
						metalStorage = tonumber(bDef.metalStorage) or 0,
						energyStorage = tonumber(bDef.energyStorage) or 0,
						techTier = unitTechTier(bDef),
					}
					found[bDefID] = item
					order[#order + 1] = bDefID
				end
			end
		end
	end

	local byCategory = {}
	for _, category in ipairs(CATEGORIES) do byCategory[category.key] = {} end
	for i = 1, #order do
		local item = found[order[i]]
		byCategory[item.category][#byCategory[item.category] + 1] = item
	end
	local factoryList = {}
	for i = 1, #factoryOrder do
		local item = factoryFound[factoryOrder[i]]
		item.queueCount = factoryQueueCounts[item.unitDefID] or 0
		local isCurrent = (item.queueCount > 0) and (factoryActiveBuilding[item.unitDefID] == true)
		item.isBuilding = isCurrent
		item.buildProgress = isCurrent and (factoryBuildingProgress[item.unitDefID] or 0) or 0
		item.buildingUnitID = isCurrent and factoryBuildingUnitIDs[item.unitDefID] or nil

		local queueIdx = 99
		for idx, defID in ipairs(factoryQueueOrder) do
			if defID == item.unitDefID then
				queueIdx = idx
				break
			end
		end
		if isCurrent then queueIdx = 1 end
		item.queueIndex = queueIdx
		factoryList[#factoryList + 1] = item
	end
	return byCategory, factoryList, selectedFactory, selectedFactoryTitle or "Factory", selectedFactoryDefID, selectedFactoryUnitID
end

-- Mirror a left click in BAR's stock menu so factory purchases enter the real
-- engine queue and update the command descriptor count.
local function queueFactory(unitDefID, amount)
	amount = max(1, floor(tonumber(amount) or 1))
	local commandIndex = commandIndexForUnitDef(unitDefID)
	local queuedCount = 0
	if commandIndex and spSetActiveCommand then
		for _ = 1, amount do
			local result = spSetActiveCommand(commandIndex, 1, true, false, false, false, false, false)
			if not result then break end
			queuedCount = queuedCount + 1
		end
		if queuedCount > 0 then
			dirty = true
			return queuedCount
		end
	end
	if not spGiveOrderToUnit then return 0 end
	for _, factoryID in ipairs(selectedFactoryIDs()) do
		for _ = 1, amount do
			spGiveOrderToUnit(factoryID, -unitDefID, {}, {})
			queuedCount = queuedCount + 1
		end
	end
	if queuedCount > 0 then dirty = true end
	return queuedCount
end

local function queueFactoryOne(unitDefID)
	return queueFactory(unitDefID, 1)
end

local function cancelFactoryQueueOne(unitDefID)
	return cancelFactoryQueue(unitDefID, 1)
end

local TIER_COLORS = {
	[1] = {0.45, 0.80, 1.00, 1.0}, -- T1: Ice Blue / Cyan (#66CCFF)
	[2] = {1.00, 0.82, 0.20, 1.0}, -- T2: Gold / Amber (#FFD133)
	[3] = {0.88, 0.32, 1.00, 1.0}, -- T3: Epic Neon Purple (#E052FF)
	[4] = {1.00, 0.22, 0.30, 1.0}, -- T4: Apex Crimson Red (#FF384D)
}

local function unitRoleLabel(def)
	if not def then return "" end
	local name = textForDef(def)
	local customParams = def.customParams or {}
	local unitGroup = lower(tostring(customParams.unitgroup or customParams.unitGroup or ""))

	if def.isFactory then
		return "Factory"
	elseif def.isBuilder or (def.buildOptions and #def.buildOptions > 0) then
		return "Builder"
	elseif contains(name, "anti-air") or contains(name, "antiair") or contains(name, "air defense") or contains(name, "flak") or contains(name, "sam") then
		return "Anti-Air"
	elseif contains(name, "artillery") or contains(name, "howitzer") or contains(name, "mortar") or contains(name, "missile") or contains(name, "rocket") or contains(name, "catapult") or contains(name, "javelin") then
		return "Artillery"
	elseif contains(name, "raider") or contains(name, "pawn") or contains(name, "grunt") or contains(name, "blitz") or contains(name, "rascal") or contains(name, "scout") or contains(name, "tick") or contains(name, "flea") or contains(name, "bandit") then
		return "Raider"
	elseif contains(name, "skirmish") or contains(name, "rocketeer") or contains(name, "thug") or contains(name, "whistler") then
		return "Skirmisher"
	elseif contains(name, "heavy") or contains(name, "assault") or contains(name, "fatboy") or contains(name, "goliath") or contains(name, "sumo") or contains(name, "mammoth") or contains(name, "bulldog") or contains(name, "behemoth") or contains(name, "juggernaut") or contains(name, "bantha") or contains(name, "titan") or contains(name, "thor") then
		return "Assault"
	elseif contains(name, "sniper") or contains(name, "sharpshooter") or contains(name, "penetrator") or contains(name, "starlight") then
		return "Sniper"
	elseif contains(name, "radar") or contains(name, "sonar") or contains(name, "sensor") or contains(name, "pinpointer") or contains(name, "spy") then
		return "Sensor"
	elseif contains(name, "jammer") or contains(name, "stealth") or contains(name, "cloak") or contains(name, "shield") or contains(name, "nano") or contains(name, "repair") or contains(name, "resurrect") or contains(name, "decoy") then
		return "Support"
	elseif contains(name, "solar") or contains(name, "wind") or contains(name, "tidal") or contains(name, "fusion") or contains(name, "geo") or contains(name, "energy") then
		return "Energy"
	elseif contains(name, "metal") or contains(name, "extractor") or contains(name, "mex") or contains(name, "maker") or contains(name, "converter") then
		return "Metal"
	elseif contains(name, "turret") or contains(name, "beamer") or contains(name, "laser") or contains(name, "plasma") or contains(name, "defense") or contains(name, "defence") or contains(name, "wall") or contains(name, "fortification") or contains(name, "mine") then
		return "Defense"
	elseif contains(name, "bomber") or contains(name, "fighter") or contains(name, "gunship") or contains(name, "aircraft") then
		return "Air"
	elseif contains(name, "submarine") or contains(name, "destroyer") or contains(name, "cruiser") or contains(name, "battleship") or contains(name, "ship") or contains(name, "boat") then
		return "Naval"
	elseif unitGroup ~= "" then
		return unitGroup:sub(1, 1):upper() .. unitGroup:sub(2)
	end
	return "Combat"
end

local ROLE_COLORS = {
	["RAIDER"]      = {1.00, 0.78, 0.20, 1.0}, -- Amber / Gold (#FFC733)
	["SKIRMISHER"]  = {1.00, 0.68, 0.22, 1.0}, -- Warm Amber (#FFAD38)
	["ASSAULT"]     = {1.00, 0.38, 0.32, 1.0}, -- Flame Red (#FF6152)
	["HEAVY"]       = {1.00, 0.32, 0.28, 1.0}, -- Crimson Red (#FF5247)
	["SNIPER"]      = {0.90, 0.40, 1.00, 1.0}, -- Magenta / Purple (#E666FF)
	["ARTILLERY"]   = {0.85, 0.35, 0.98, 1.0}, -- Electric Purple (#D959FA)
	["ANTI-AIR"]    = {0.25, 0.78, 1.00, 1.0}, -- Sky Cyan (#40C7FF)
	["AIR"]         = {0.35, 0.85, 1.00, 1.0}, -- Aero Blue (#59D9FF)
	["NAVAL"]       = {0.20, 0.65, 0.95, 1.0}, -- Ocean Blue (#33A6F2)
	["BUILDER"]     = {0.30, 0.95, 0.55, 1.0}, -- Emerald Green (#4DF28C)
	["FACTORY"]     = {0.25, 0.88, 0.50, 1.0}, -- Factory Green (#40E080)
	["ENERGY"]      = {1.00, 0.88, 0.25, 1.0}, -- Solar Yellow (#FFE040)
	["METAL"]       = {0.75, 0.85, 0.95, 1.0}, -- Metal Silver (#BFD9F2)
	["DEFENSE"]     = {0.95, 0.45, 0.30, 1.0}, -- Defense Terracotta (#F2734D)
	["SENSOR"]      = {0.45, 0.65, 1.00, 1.0}, -- Sensor Blue (#73A6FF)
	["SUPPORT"]     = {0.55, 0.60, 1.00, 1.0}, -- Indigo Support (#8C99FF)
	["COMBAT"]      = {0.95, 0.40, 0.35, 1.0}, -- Default Combat (#F26659)
}

-- Multi-stop smooth cosine color gradient:
-- เขียว (Green) -> เหลือง (Yellow) -> ส้ม (Orange) -> แดง (Red) -> ม่วง (Purple) -> น้ำเงิน (Blue)
local QUEUE_GRADIENT_STOPS = {
	{0.22, 1.00, 0.38}, -- 1: เขียวสด (Bright Green)
	{0.68, 1.00, 0.20}, -- 1.5: เขียวตองอ่อน (Lime Green)
	{1.00, 0.92, 0.12}, -- 2: เหลืองสว่าง (Bright Yellow)
	{1.00, 0.70, 0.12}, -- 2.5: เหลืองอมส้ม (Amber)
	{1.00, 0.48, 0.10}, -- 3: ส้มสด (Vibrant Orange)
	{1.00, 0.28, 0.18}, -- 3.5: ส้มอมแดง (Coral Red)
	{1.00, 0.20, 0.28}, -- 4: แดงสด (Crimson Red)
	{0.92, 0.22, 0.65}, -- 4.5: ชมพูม่วง (Magenta)
	{0.80, 0.28, 0.98}, -- 5: ม่วงสด (Electric Purple)
	{0.48, 0.45, 1.00}, -- 5.5: ม่วงคราม (Indigo)
	{0.18, 0.68, 1.00}, -- 6: น้ำเงินสว่าง (Neon Blue)
}

local function getQueueGradientColor(queueIndex, isBuilding)
	if isBuilding or (queueIndex or 1) <= 1 then
		local c = QUEUE_GRADIENT_STOPS[1]
		return {c[1], c[2], c[3], 1.0}
	end

	local numStops = #QUEUE_GRADIENT_STOPS
	local t = math.max(0, math.min(1, ((queueIndex or 2) - 1) / 5.0))
	local scaled = t * (numStops - 1) + 1
	local idx1 = math.floor(scaled)
	local idx2 = math.min(numStops, idx1 + 1)
local frac = scaled - idx1

	-- Cosine interpolation for velvety smooth color transition
	local smoothFrac = 0.5 * (1 - math.cos(frac * math.pi))

	local c1 = QUEUE_GRADIENT_STOPS[idx1]
	local c2 = QUEUE_GRADIENT_STOPS[idx2]

	local r = c1[1] + (c2[1] - c1[1]) * smoothFrac
	local g = c1[2] + (c2[2] - c1[2]) * smoothFrac
	local b = c1[3] + (c2[3] - c1[3]) * smoothFrac

	return {r, g, b, 1.0}
end

local function drawQueueRibbon(cardX, cardY, cardW, cardH, titleBandY, count, isBuilding, queueIdx, buildProgress, etaStr)
	local countStr = tostring(count)
	local countColor = getQueueGradientColor(queueIdx, isBuilding)
	local ribbonH = 22 * uiScale
	local ribbonX = cardX + 2 * uiScale
	local ribbonW = cardW - 4 * uiScale
	local ribbonY = cardY + (cardH - ribbonH) * 0.5

	local progress = 0
	if isBuilding and buildProgress and buildProgress > 0 then
		progress = math.max(0, math.min(1, buildProgress))
	end

	local centerLabel = ""
	if isBuilding then
		if etaStr and etaStr ~= "" then
			centerLabel = string.format("BUILDING x%s (%s)", countStr, etaStr)
		else
			centerLabel = "BUILDING  x" .. countStr
		end
	else
		centerLabel = "QUEUED  x" .. countStr
	end
	local textCenterX = ribbonX + ribbonW * 0.5
	local textCenterY = ribbonY + ribbonH * 0.5
	local textSize = 11 * uiScale

	-- 1. BASE LAYER: Original Colored Queue Ribbon (Right / Remaining Portion)
	local splitX = ribbonX + ribbonW * progress
	if isBuilding and progress > 0 and progress < 1 then
		gl.Scissor(floor(splitX), floor(ribbonY), max(1, floor(ribbonX + ribbonW - splitX)), max(1, floor(ribbonH)))
	else
		gl.Scissor(floor(ribbonX), floor(ribbonY), max(1, floor(ribbonW)), max(1, floor(ribbonH)))
	end

	-- Dark glass backing for original queue
	glColor(0.012, 0.030, 0.050, 0.54)
	glRect(ribbonX, ribbonY, ribbonX + ribbonW, ribbonY + ribbonH)

	-- Tinted inner glow with original queue color
	glColor(countColor[1], countColor[2], countColor[3], isBuilding and 0.16 or 0.10)
	glRect(ribbonX + 1 * uiScale, ribbonY + 1 * uiScale, ribbonX + ribbonW - 1 * uiScale, ribbonY + ribbonH - 1 * uiScale)

	-- Top & bottom borders in original queue color
	glColor(countColor[1], countColor[2], countColor[3], isBuilding and 0.58 or 0.45)
	glRect(ribbonX, ribbonY, ribbonX + ribbonW, ribbonY + 1 * uiScale)
	glRect(ribbonX, ribbonY + ribbonH - 1 * uiScale, ribbonX + ribbonW, ribbonY + ribbonH)

	-- Right end glowing cap in original queue color
	glColor(countColor[1], countColor[2], countColor[3], 0.60)
	glRect(ribbonX + ribbonW - 3 * uiScale, ribbonY, ribbonX + ribbonW, ribbonY + ribbonH)

	-- Text in original queue color
	local origTextColor = {countColor[1], countColor[2], countColor[3], (countColor[4] or 1.0) * 0.90}
	drawText(centerLabel, textCenterX, textCenterY, textSize, origTextColor, "voco")
	gl.Scissor(false)

	-- 2. PROGRESS OVERLAY LAYER: Titanium/Slate Gray Completed Ribbon (Left / Built Progress Portion)
	if isBuilding and progress > 0 then
		local whiteW = ribbonW * progress
		gl.Scissor(floor(ribbonX), floor(ribbonY), max(1, floor(whiteW)), max(1, floor(ribbonH)))

		-- Translucent metallic slate-gray glass backing
		glColor(0.20, 0.26, 0.34, 0.45)
		glRect(ribbonX, ribbonY, ribbonX + ribbonW, ribbonY + ribbonH)

		-- Soft slate-gray inner highlight glow
		glColor(0.55, 0.65, 0.75, 0.16)
		glRect(ribbonX + 1 * uiScale, ribbonY + 1 * uiScale, ribbonX + ribbonW - 1 * uiScale, ribbonY + ribbonH - 1 * uiScale)

		-- Top & bottom crisp titanium-gray borders
		glColor(0.70, 0.78, 0.86, 0.75)
		glRect(ribbonX, ribbonY, ribbonX + ribbonW, ribbonY + 1 * uiScale)
		glRect(ribbonX, ribbonY + ribbonH - 1 * uiScale, ribbonX + ribbonW, ribbonY + ribbonH)

		-- Left end crisp gray cap
		glColor(0.75, 0.82, 0.90, 0.80)
		glRect(ribbonX, ribbonY, ribbonX + 3 * uiScale, ribbonY + ribbonH)

		-- Text in cool silver-gray
		drawText(centerLabel, textCenterX, textCenterY, textSize, {0.80, 0.86, 0.92, 1.0}, "voco")
		gl.Scissor(false)

		-- 3. Titanium-Gray Leading Frontier Line (เส้นคาดแนวตั้งสูงเท่ากับขอบซ้ายพอดีเป๊ะ)
		if progress < 0.995 then
			-- Crisp vertical divider line (Exact same height as left edge)
			glColor(0.88, 0.93, 0.98, 0.95)
			glRect(splitX - 1.5 * uiScale, ribbonY, splitX + 1.5 * uiScale, ribbonY + ribbonH)
			-- Soft horizontal aura flare (Bounded strictly within ribbon height)
			glColor(0.65, 0.75, 0.85, 0.25)
			glRect(splitX - 3.5 * uiScale, ribbonY, splitX + 3.5 * uiScale, ribbonY + ribbonH)
		end
	end
end

local function activateBuildCommand(unitDefID)
	-- 1. If in pregame (before clicking ready / countdown), use BAR's native Pregame Queue system!
	if isPregameState() then
		if WG and WG["pregame-build"] and WG["pregame-build"].setPreGamestartDefID then
			WG["pregame-build"].setPreGamestartDefID(unitDefID)
			dirty = true
			return true
		end
	end

	-- 2. Regular in-game activation
	if not spSetActiveCommand then return false end

	-- Ensure commander or builder is selected
	local selected = spGetSelectedUnits and spGetSelectedUnits() or {}
	local comID = nil
	if #selected == 0 then
		comID = autoSelectCommanderIfNoneSelected()
	else
		comID = selected[1]
	end

	if comID and Spring.ValidUnitID(comID) and spSelectUnitArray then
		spSelectUnitArray({ comID })
	end

	-- Lookup command index from engine active descriptors
	local commandIndex = commandIndexForUnitDef(unitDefID)
	if not commandIndex and spGetCmdDescIndex then
		commandIndex = spGetCmdDescIndex(-unitDefID)
	end

	-- If not found in active descs, lookup directly in unit's own cmd descs
	if not commandIndex and comID and spGetUnitCmdDescs then
		local descs = spGetUnitCmdDescs(comID)
		if descs then
			for i = 1, #descs do
				local cmd = descs[i]
				if cmd and cmd.id == -unitDefID then
					commandIndex = i
					break
				end
			end
		end
	end

	-- Activate command with simulated left-click and modifier keys
	if commandIndex and spSetActiveCommand then
		local alt, ctrl, meta, shift = false, false, false, false
		if spGetModKeyState then
			alt, ctrl, meta, shift = spGetModKeyState()
		end
		spSetActiveCommand(commandIndex, 1, true, false, alt or false, ctrl or false, meta or false, shift or false)
		pendingBuildUnitDefID = nil
		dirty = true
		return true
	end

	pendingBuildUnitDefID = unitDefID
	dirty = true
	return false
end

local function sortCardsByCost(list)
	table.sort(list, function(a, b)
		local aMetal = a.metal or 0
		local bMetal = b.metal or 0
		if aMetal ~= bMetal then return aMetal < bMetal end
		local aEnergy = a.energy or 0
		local bEnergy = b.energy or 0
		if aEnergy ~= bEnergy then return aEnergy < bEnergy end
		return lower(a.name or "") < lower(b.name or "")
	end)
end

local function formatFlow(makeValue, useValue)
	local parts = {}
	if (makeValue or 0) > 0.01 then
		parts[#parts + 1] = "+" .. formatCost(makeValue)
	end
	if (useValue or 0) > 0.01 then
		parts[#parts + 1] = "-" .. formatCost(useValue)
	end
	return #parts > 0 and table.concat(parts, "/") or nil
end

local function flowColor(makeValue, useValue)
	if (makeValue or 0) > 0.01 and (useValue or 0) <= 0.01 then
		return {0.45, 1.0, 0.50, 1}
	elseif (useValue or 0) > 0.01 and (makeValue or 0) <= 0.01 then
		return {1.0, 0.48, 0.42, 1}
	end
	return {0.88, 0.92, 0.96, 1}
end

local function refresh()
	-- Tier tabs are intentionally hidden; always show the complete list.
	activeTier = 0
	local byCategory, factoryList, selectedFactory, selectedFactoryTitle, selectedFactoryDefID, selectedFactoryUnitID = selectedBuildCommands()
	availableByCategory = byCategory
	factoryMode = selectedFactory
	factoryTitle = selectedFactoryTitle
	if selectedFactoryDefID ~= factorySourceID then
		activeTier = 0
		cardScroll = 0
		factorySourceID = selectedFactoryDefID
		factorySourceUnitID = selectedFactoryUnitID
	else
		factorySourceUnitID = selectedFactoryUnitID or factorySourceUnitID
	end
	factoryAllCards = factoryList
	factoryQueueTotal = 0
	for i = 1, #factoryAllCards do
		factoryQueueTotal = factoryQueueTotal + (factoryAllCards[i].queueCount or 0)
	end
	if factoryMode then
		cards = {}
		for i = 1, #factoryAllCards do
			local item = factoryAllCards[i]
			if activeTier == 0 or item.techTier == activeTier then
				cards[#cards + 1] = item
			end
		end
		sortCardsByCost(cards)
		factoryCards = cards
		visible = #factoryAllCards > 0
	else
		factoryCards = {}
		cards = {}
		local categoryCards = availableByCategory[activeCategory] or {}
		if #categoryCards == 0 then
			for _, category in ipairs(CATEGORIES) do
				if #(availableByCategory[category.key] or {}) > 0 then
					activeCategory = category.key
					categoryCards = availableByCategory[activeCategory] or {}
					break
				end
			end
		end
		for i = 1, #categoryCards do
			local item = categoryCards[i]
			if activeTier == 0 or item.techTier == activeTier then
				cards[#cards + 1] = item
			end
		end
		sortCardsByCost(cards)
		-- Keep the panel open when the selected category/tier is empty so the
		-- player can switch either tab without losing the construction context.
		visible = false
		for _, category in ipairs(CATEGORIES) do
			if #(availableByCategory[category.key] or {}) > 0 then
				visible = true
				break
			end
		end
	end
	dirty = false
end

local function categoryIndex(key)
	for i = 1, #CATEGORIES do
		if CATEGORIES[i].key == key then return i end
	end
	return 1
end

local function panelMetrics()
	local cardW = CARD_WIDTH * uiScale
	local cardH = CARD_HEIGHT * uiScale
	local gap = CARD_GAP * uiScale
	local pad = 10 * uiScale
	local headerH = 26 * uiScale
	local headerGap = 6 * uiScale
	local allRows = max(1, ceil(#cards / CARD_COLUMNS))
	local panelW = pad * 2 + CARD_COLUMNS * cardW + (CARD_COLUMNS - 1) * gap
	-- Keep the category name and its shortcut on one compact baseline.  The
	-- shortcut is right-aligned so every tab remains easy to scan at a glance.
	local categoryTabH = 32 * uiScale
	local categoryTabGap = 4 * uiScale
	local categoryRows = max(1, ceil(#CATEGORIES / CATEGORY_COLUMNS))
	local categoryAreaH = categoryRows * categoryTabH + (categoryRows - 1) * categoryTabGap
	local tierTabH = 0
	-- Keep the bottom category strip visually separate from the card price
	-- line (M/E); the strip remains anchored at the bottom of the panel.
	local tabGap = 8 * uiScale
	local x = (PANEL_LEFT + panelOffsetX) * uiScale
	local y = (PANEL_BOTTOM + panelOffsetY) * uiScale
	-- Keep the complete list available without letting a large faction roster
	-- push the panel off-screen. Extra rows are reachable with the mouse wheel.
	local reservedH = pad * 2 + headerH + headerGap + tierTabH + tabGap + categoryAreaH
	local topMargin = 12 * uiScale
	local maxCardAreaH = max(cardH, vsy - y - topMargin - reservedH)
	local maxRows = min(CARD_MAX_ROWS, max(1, floor((maxCardAreaH + gap) / (cardH + gap))))
	local rows = min(allRows, maxRows)
	visibleRows = rows
	totalRows = allRows
	maxCardScroll = max(0, allRows - rows)
	cardScroll = min(maxCardScroll, max(0, cardScroll))
	local panelH = pad + rows * cardH + (rows - 1) * gap + headerGap + headerH + tierTabH + tabGap + categoryAreaH + pad
	return x, y, panelW, panelH, cardW, cardH, gap, pad, categoryTabH, categoryAreaH, categoryTabGap, tierTabH, tabGap, rows, allRows, categoryRows, headerH, headerGap
end

local function drawCard(x, y, w, h, item, showQueueControls, cardIndex, totalCards, cardScale)
	local sScale = uiScale * (cardScale or 1.0)
	local hovered = isInRect(screenMouseX, screenMouseY, x, y, x + w, y + h)
	if hovered then
		hoveredItem = item
	end
	local cardBg = hovered and {0.035, 0.070, 0.095, 0.12} or UI_COLORS.card
	if cardBg[4] > 0 then
		glColor(cardBg[1], cardBg[2], cardBg[3], cardBg[4])
		glRect(x, y, x + w, y + h)
	end

	local vsBadgeText = nil
	local vsBadgeColor = nil
	if pinnedCompareItem and pinnedCompareItem.unitDefID == item.unitDefID then
		vsBadgeText = "VS 1"
		vsBadgeColor = {1.00, 0.85, 0.20, 1.0}
	elseif pinnedCompareItemB and pinnedCompareItemB.unitDefID == item.unitDefID then
		vsBadgeText = "VS 2"
		vsBadgeColor = {0.30, 0.85, 1.00, 1.0}
	elseif pinnedCompareItem and not pinnedCompareItemB and hovered and item.unitDefID ~= pinnedCompareItem.unitDefID then
		vsBadgeText = "VS 2"
		vsBadgeColor = {0.30, 0.85, 1.00, 1.0}
	end

	if vsBadgeColor then
		glColor(vsBadgeColor[1], vsBadgeColor[2], vsBadgeColor[3], 0.95)
		glRect(x, y, x + w, y + 2 * sScale)
		glRect(x, y + h - 2 * sScale, x + w, y + h)
		glRect(x, y, x + 2 * sScale, y + h)
		glRect(x + w - 2 * sScale, y, x + w, y + h)
	elseif hovered then
		drawHoverGlow(x, y, x + w, y + h, {0.38, 0.88, 1.0, 1.0})
	else
		glColor(UI_COLORS.cardBorder[1], UI_COLORS.cardBorder[2], UI_COLORS.cardBorder[3], UI_COLORS.cardBorder[4])
		glRect(x, y, x + w, y + 1 * sScale)
		glRect(x, y + h - 1 * sScale, x + w, y + h)
		glRect(x, y, x + 1 * sScale, y + h)
		glRect(x + w - 1 * sScale, y, x + w, y + h)
	end

	-- Top title band (100% transparent glass header)
	local titleBandH = 30 * sScale
	local titleBandY = y + h - titleBandH - 2 * sScale
	-- Top luminous cyan accent line (subtle shine)
	if vsBadgeColor then
		glColor(vsBadgeColor[1], vsBadgeColor[2], vsBadgeColor[3], 0.85)
	else
		glColor(0.40, 0.78, 0.98, 0.65)
	end
	glRect(x + 3 * sScale, y + h - 3 * sScale, x + w - 3 * sScale, y + h - 2 * sScale)
	-- Bottom divider line
	glColor(0.25, 0.48, 0.65, 0.45)
	glRect(x + 2 * sScale, titleBandY, x + w - 2 * sScale, titleBandY + 1 * sScale)

	-- 1. Strategic Icon (Top-Left framed glass capsule - 100% transparent inside)
	local iconSize = 22 * sScale
	local iconBoxSize = 24 * sScale
	local iconBoxX = x + 5 * sScale
	local iconBoxY = titleBandY + (titleBandH - iconBoxSize) * 0.5

	glColor(0.35, 0.65, 0.85, 0.55)
	glRect(iconBoxX, iconBoxY, iconBoxX + iconBoxSize, iconBoxY + 1 * sScale)
	glRect(iconBoxX, iconBoxY + iconBoxSize - 1 * sScale, iconBoxX + iconBoxSize, iconBoxY + iconBoxSize)
	glRect(iconBoxX, iconBoxY, iconBoxX + 1 * sScale, iconBoxY + iconBoxSize)
	glRect(iconBoxX + iconBoxSize - 1 * sScale, iconBoxY, iconBoxX + iconBoxSize, iconBoxY + iconBoxSize)

	local iconX = iconBoxX + (iconBoxSize - iconSize) * 0.5
	local iconY = iconBoxY + (iconBoxSize - iconSize) * 0.5
	drawStrategicIcon(iconX, iconY, iconSize, item)

	-- 2. Unit Name (Top header bar - full width restored)
	local iconTextGap = 7 * sScale
	local titleX = iconBoxX + iconBoxSize + iconTextGap
	local titleRight = x + w - 7 * sScale
	local titleSize = 10.5 * sScale
	local maxTitleW = max(1, titleRight - titleX)
	local title = fitTitleToWidth(item.name, maxTitleW, titleSize)
	local titleY = titleBandY + titleBandH * 0.5
	gl.Scissor(floor(titleX), floor(titleBandY), max(1, floor(maxTitleW)), max(1, floor(titleBandH)))
	drawText(title, titleX, titleY, titleSize, {0.96, 0.98, 1.0, 1.0}, "vo")
	gl.Scissor(false)

	-- Bottom price band (100% transparent inside)
	local priceBandH = 28 * sScale
	local priceBandY = y + 2 * sScale
	glColor(0.25, 0.48, 0.65, 0.45)
	glRect(x + 2 * sScale, priceBandY + priceBandH - 1 * sScale, x + w - 2 * sScale, priceBandY + priceBandH)

	-- Middle 3D Preview area
	local modelX = x + 6 * sScale
	local modelY = y + priceBandH + 4 * sScale
	local modelW = w - 12 * sScale
	local modelH = h - titleBandH - priceBandH - 8 * sScale

	local motion = resolveModelMotion()
	local drewModel = drawUnitModel(modelX, modelY, modelW, modelH, item.unitDefID, motion)
	if not drewModel then
		local tint = item.disabled and 0.42 or 1
		glColor(tint, tint, tint, 1)
		glTexture("#" .. item.unitDefID)
		glTexRect(modelX, modelY, modelX + modelW, modelY + modelH)
		glTexture(false)
	end

	-- Calculate exact vertical midpoints for floating badges
	local priceTopY = priceBandY + priceBandH
	local queueRibbonH = 22 * sScale
	local queueRibbonBottomY = y + (h - queueRibbonH) * 0.5
	local queueRibbonTopY = y + (h + queueRibbonH) * 0.5
	local badgeH = 16 * sScale
	local badgeY = priceTopY + (queueRibbonBottomY - priceTopY - badgeH) * 0.5
	local topBadgeY = queueRibbonTopY + (titleBandY - queueRibbonTopY - badgeH) * 0.5
	if topBadgeY >= titleBandY - badgeH - 2 * sScale then
		topBadgeY = titleBandY - badgeH - 3 * sScale
	end

	-- 3. VS 1 / VS 2 Badge (Upper-Right Floating Badge - 100% transparent inside)
	if vsBadgeText and vsBadgeColor then
		local vsBadgeW = 28 * sScale
		local vsBadgeX = x + w - vsBadgeW - 3 * sScale
		local vsBadgeY = topBadgeY

		-- Tinted glow matching VS color
		glColor(vsBadgeColor[1], vsBadgeColor[2], vsBadgeColor[3], 0.20)
		glRect(vsBadgeX + 1 * sScale, vsBadgeY + 1 * sScale, vsBadgeX + vsBadgeW - 1 * sScale, vsBadgeY + badgeH - 1 * sScale)

		-- 1px border colored with VS color
		glColor(vsBadgeColor[1], vsBadgeColor[2], vsBadgeColor[3], 0.90)
		glRect(vsBadgeX, vsBadgeY, vsBadgeX + vsBadgeW, vsBadgeY + 1 * sScale)
		glRect(vsBadgeX, vsBadgeY + badgeH - 1 * sScale, vsBadgeX + vsBadgeW, vsBadgeY + badgeH)
		glRect(vsBadgeX, vsBadgeY, vsBadgeX + 1 * sScale, vsBadgeY + badgeH)
		glRect(vsBadgeX + vsBadgeW - 1 * sScale, vsBadgeY, vsBadgeX + vsBadgeW, vsBadgeY + badgeH)

		-- Text "VS 1" / "VS 2" centered inside badge
		gl.Scissor(floor(vsBadgeX + 1 * sScale), floor(vsBadgeY), max(1, floor(vsBadgeW - 2 * sScale)), max(1, floor(badgeH)))
		drawText(vsBadgeText, vsBadgeX + vsBadgeW * 0.5, vsBadgeY + badgeH * 0.5, 9.0 * sScale, vsBadgeColor, "voco")
		gl.Scissor(false)
	end

	-- 4. Sub-Role Category Badge (Left - 100% transparent inside)
	local def = UnitDefs[item.unitDefID]
	local role = unitRoleLabel(def)
	local roleH = badgeH
	local roleY = badgeY
	local roleW = 0

	if role and role ~= "" then
		local roleStr = upper(role)
		local roleColor = ROLE_COLORS[roleStr] or {0.68, 0.84, 0.96, 1.0}
		local roleFontSize = 7.8 * sScale
		local textW = getTextPixelWidth(roleStr, roleFontSize)
		local rolePadX = 7 * sScale
		local maxRoleW = (w - 20 * sScale) * 0.55
		roleW = min(maxRoleW, max(22 * sScale, textW + rolePadX * 2 + 5 * sScale))
		local roleX = x + 3 * sScale

		-- Tinted glow matching role color
		glColor(roleColor[1], roleColor[2], roleColor[3], 0.16)
		glRect(roleX + 1 * sScale, roleY + 1 * sScale, roleX + roleW - 1 * sScale, roleY + roleH - 1 * sScale)

		-- 1px border colored with Role Color
		glColor(roleColor[1], roleColor[2], roleColor[3], 0.75)
		glRect(roleX, roleY, roleX + roleW, roleY + 1 * sScale)
		glRect(roleX, roleY + roleH - 1 * sScale, roleX + roleW, roleY + roleH)
		glRect(roleX, roleY, roleX + 1 * sScale, roleY + roleH)
		glRect(roleX + roleW - 1 * sScale, roleY, roleX + roleW, roleY + roleH)

		-- Right indicator pip (cleanly separated from text on the right)
		glColor(roleColor[1], roleColor[2], roleColor[3], 0.95)
		glRect(roleX + roleW - 4.5 * sScale, roleY + 3.5 * sScale, roleX + roleW - 2.5 * sScale, roleY + roleH - 3.5 * sScale)

		-- Role text with scissor containment and generous right margin
		gl.Scissor(floor(roleX + 2 * sScale), floor(roleY), max(1, floor(roleW - 7 * sScale)), max(1, floor(roleH)))
		drawText(roleStr, roleX + (roleW - 4 * sScale) * 0.5, roleY + roleH * 0.5, roleFontSize, roleColor, "voco")
		gl.Scissor(false)
	end

	-- 5. Tech Tier Badge (Right - 100% transparent inside)
	local tier = item.techTier or 1
	local tierStr = "T" .. tostring(tier)
	local tierColor = TIER_COLORS[tier] or TIER_COLORS[1]
	local tierBadgeW = 26 * sScale
	local tierBadgeH = badgeH
	local tierBadgeX = x + w - tierBadgeW - 3 * sScale
	local tierBadgeY = badgeY

	-- Tinted glow
	glColor(tierColor[1], tierColor[2], tierColor[3], 0.18)
	glRect(tierBadgeX + 1 * sScale, tierBadgeY + 1 * sScale, tierBadgeX + tierBadgeW - 1 * sScale, tierBadgeY + tierBadgeH - 1 * sScale)

	-- 1px border colored with Tier Color
	glColor(tierColor[1], tierColor[2], tierColor[3], 0.85)
	glRect(tierBadgeX, tierBadgeY, tierBadgeX + tierBadgeW, tierBadgeY + 1 * sScale)
	glRect(tierBadgeX, tierBadgeY + tierBadgeH - 1 * sScale, tierBadgeX + tierBadgeW, tierBadgeY + tierBadgeH)
	glRect(tierBadgeX, tierBadgeY, tierBadgeX + 1 * sScale, tierBadgeY + tierBadgeH)
	glRect(tierBadgeX + tierBadgeW - 1 * sScale, tierBadgeY, tierBadgeX + tierBadgeW, tierBadgeY + tierBadgeH)

	-- Text "T1", "T2", "T3" centered inside badge with comfortable breathing room
	gl.Scissor(floor(tierBadgeX + 1 * sScale), floor(tierBadgeY), max(1, floor(tierBadgeW - 2 * sScale)), max(1, floor(tierBadgeH)))
	drawText(tierStr, tierBadgeX + tierBadgeW * 0.5, tierBadgeY + tierBadgeH * 0.5, 9.0 * sScale, tierColor, "voco")
	gl.Scissor(false)

	-- 5. Prices: High-Tech Dual Symmetrical Capsules (Metal left, Energy right - 100% transparent inside)
	local pillPad = 4 * sScale
	local pillGap = 5 * sScale
	local totalPillSpace = (w - 4 * sScale) - (pillPad * 2) - pillGap
	local pillW = totalPillSpace * 0.5
	local pillH = 20 * sScale
	local pillY = priceBandY + (priceBandH - pillH) * 0.5

	-- Metal Capsule (Left 50%)
	local mX = x + 2 * sScale + pillPad
	local mY = pillY
	glColor(0.35, 0.70, 0.92, 0.12)
	glRect(mX + 1 * sScale, mY + 1 * sScale, mX + pillW - 1 * sScale, mY + pillH - 1 * sScale)
	glColor(0.35, 0.65, 0.85, 0.50)
	glRect(mX, mY, mX + pillW, mY + 1 * sScale)
	glRect(mX, mY + pillH - 1 * sScale, mX + pillW, mY + pillH)
	glRect(mX, mY, mX + 1 * sScale, mY + pillH)
	glRect(mX + pillW - 1 * sScale, mY, mX + pillW, mY + pillH)
	glColor(0.45, 0.85, 1.0, 0.90)
	glRect(mX + 2.5 * sScale, mY + 3 * sScale, mX + 5 * sScale, mY + pillH - 3 * sScale)
	gl.Scissor(floor(mX + 6 * sScale), floor(mY), max(1, floor(pillW - 7 * sScale)), max(1, floor(pillH)))
	drawText(formatCost(item.metal) .. " M", mX + pillW * 0.5 + 2 * sScale, mY + pillH * 0.5, 9.5 * sScale, {0.90, 0.96, 1.0, 1.0}, "voco")
	gl.Scissor(false)

	-- Energy Capsule (Right 50%)
	local eX = mX + pillW + pillGap
	local eY = pillY
	glColor(1.0, 0.80, 0.15, 0.12)
	glRect(eX + 1 * sScale, eY + 1 * sScale, eX + pillW - 1 * sScale, eY + pillH - 1 * sScale)
	glColor(0.85, 0.68, 0.18, 0.50)
	glRect(eX, eY, eX + pillW, eY + 1 * sScale)
	glRect(eX, eY + pillH - 1 * sScale, eX + pillW, eY + pillH)
	glRect(eX, eY, eX + 1 * sScale, eY + pillH)
	glRect(eX + pillW - 1 * sScale, eY, eX + pillW, eY + pillH)
	glColor(1.0, 0.85, 0.20, 0.90)
	glRect(eX + 2.5 * sScale, eY + 3 * sScale, eX + 5 * sScale, eY + pillH - 3 * sScale)
	gl.Scissor(floor(eX + 6 * sScale), floor(eY), max(1, floor(pillW - 7 * sScale)), max(1, floor(pillH)))
	drawText(formatCost(item.energy) .. " E", eX + pillW * 0.5 + 2 * sScale, eY + pillH * 0.5, 9.5 * sScale, {1.0, 0.88, 0.22, 1.0}, "voco")
	gl.Scissor(false)

	local queueControls
	if showQueueControls then
		local count = item.queueCount or 0
		if count > 0 then
			local isCurrent = (item.isBuilding == true)
			local queueIdx = item.queueIndex or (isCurrent and 1 or 2)

			local currentProgress = item.buildProgress or 0
			local bUnitID = item.buildingUnitID
			if isCurrent and not bUnitID and factorySourceUnitID and Spring.ValidUnitID(factorySourceUnitID) then
				bUnitID = spGetUnitIsBuilding and spGetUnitIsBuilding(factorySourceUnitID)
			end
			if bUnitID and Spring.ValidUnitID(bUnitID) and spGetUnitHealth then
				local _, _, _, _, bp = spGetUnitHealth(bUnitID)
				if bp then
					currentProgress = bp
					updateETAState(bUnitID, bp)
				end
			end
			local etaStr = isCurrent and getETAString(bUnitID) or nil
			drawQueueRibbon(x, y, w, h, titleBandY, count, isCurrent, queueIdx, currentProgress, etaStr)
		end
	end

	if item.disabled then
		glColor(0.0, 0.0, 0.0, 0.46)
		glRect(x + 1 * sScale, y + 30 * sScale, x + w - 1 * sScale, y + h - 36 * sScale)
	end

	return queueControls
end

local function factoryPanelMetrics()
	local cardW = FACTORY_CARD_WIDTH * uiScale
	local cardH = FACTORY_CARD_HEIGHT * uiScale
	local gap = CARD_GAP * uiScale
	local pad = 10 * uiScale
	local headerH = 26 * uiScale
	local headerGap = 6 * uiScale
	local tierTabH = 0
	local allRows = max(1, ceil(#cards / FACTORY_COLUMNS))
	local panelW = pad * 2 + FACTORY_COLUMNS * cardW + (FACTORY_COLUMNS - 1) * gap
	local x = (PANEL_LEFT + panelOffsetX) * uiScale
	local y = (PANEL_BOTTOM + panelOffsetY) * uiScale
	local reservedH = pad * 2 + headerH + headerGap + tierTabH
	local topMargin = 12 * uiScale
	local maxCardAreaH = max(cardH, vsy - y - topMargin - reservedH)
	local maxRows = min(FACTORY_MAX_ROWS, max(1, floor((maxCardAreaH + gap) / (cardH + gap))))
	local rows = min(allRows, maxRows)
	visibleRows = rows
	totalRows = allRows
	maxCardScroll = max(0, allRows - rows)
	cardScroll = min(maxCardScroll, max(0, cardScroll))
	local cardAreaH = rows * cardH + (rows - 1) * gap
	local panelH = pad + cardAreaH + headerGap + headerH + pad
	return x, y, panelW, panelH, cardW, cardH, gap, pad, headerH, headerGap, tierTabH, rows, allRows
end

local function drawTopHeaderBar(x, y, panelW, panelH, headerH, activeColor)
	local headerPad = 8 * uiScale
	local headerX = x + headerPad
	local headerW = panelW - headerPad * 2
	local headerY = y + panelH - 8 * uiScale - headerH

	-- Translucent Dark Header background
	glColor(0.020, 0.045, 0.070, 0.76)
	glRect(headerX, headerY, headerX + headerW, headerY + headerH)

	-- Top glowing accent line with active theme color
	glColor(activeColor[1], activeColor[2], activeColor[3], 0.90)
	glRect(headerX, headerY + headerH - 1.5 * uiScale, headerX + headerW, headerY + headerH)

	-- Bottom divider line
	glColor(0.35, 0.65, 0.85, 0.45)
	glRect(headerX, headerY, headerX + headerW, headerY + 1 * uiScale)

	-- Side borders
	glColor(0.35, 0.65, 0.85, 0.45)
	glRect(headerX, headerY, headerX + 1 * uiScale, headerY + headerH)
	glRect(headerX + headerW - 1 * uiScale, headerY, headerX + headerW, headerY + headerH)

	-- Left glowing pip indicator
	glColor(activeColor[1], activeColor[2], activeColor[3], 1.0)
	glRect(headerX + 8 * uiScale, headerY + 6 * uiScale, headerX + 11.5 * uiScale, headerY + headerH - 6 * uiScale)

	-- Modder Title & Credits in English (Styled Dual-Tone Typography)
	local nameText = "[The]End"
	drawText(nameText, headerX + 18 * uiScale, headerY + headerH * 0.5, 10.5 * uiScale, {1.0, 0.88, 0.32, 1.0}, "vo")

	local nameW = getTextPixelWidth(nameText, 10.5 * uiScale)
	local subCredit = " • Thai Modder"
	drawText(subCredit, headerX + 18 * uiScale + nameW + 2 * uiScale, headerY + headerH * 0.5, 9.0 * uiScale, {0.75, 0.85, 0.95, 0.85}, "vo")

	-- Right Subtitle / Category
	local rightText = factoryMode and (factoryTitle or "FACTORY QUEUE") or "BUILD MENU"
	drawText(rightText, headerX + headerW - 10 * uiScale, headerY + headerH * 0.5, 9.0 * uiScale, {0.55, 0.78, 0.95, 0.80}, "vro")

	-- Header acts as the top panel drag handle
	dragHandle = {x1 = headerX, x2 = headerX + headerW, y1 = headerY, y2 = headerY + headerH}
end

local function drawFactoryMenu()
	local x, y, panelW, panelH, cardW, cardH, gap, pad, headerH, headerGap, tierTabH, rows, allRows = factoryPanelMetrics()
	menuX, menuY, menuW, menuH = x, y, panelW, panelH

	drawGlassRect(x, y, x + panelW, y + panelH, UI_COLORS.panel, UI_COLORS.panelBorder, UI_COLORS.accent)
	if SHOW_3D_MODELS and gl.UnitShape and (GL and GL.DEPTH_BUFFER_BIT) then
		gl.Clear((GL and GL.DEPTH_BUFFER_BIT))
	end

	drawTopHeaderBar(x, y, panelW, panelH, headerH, UI_COLORS.accent or {0.38, 0.88, 1.0, 1.0})
	tierTabs = {}
	tabs = {}

	local cardAreaBottom = y + pad

	-- Scrollbar (Draw underneath cards so hovered card floats above scrollbar)
	if allRows > rows then
		local trackW = 5 * uiScale
		local trackX = x + panelW - trackW - 3 * uiScale
		local trackY = cardAreaBottom
		local trackH = rows * cardH + (rows - 1) * gap
		local thumbH = max(22 * uiScale, trackH * rows / allRows)
		local thumbY = trackY + (trackH - thumbH) * (cardScroll / maxCardScroll)
		glColor(0.010, 0.022, 0.035, 0.80)
		glRect(trackX, trackY, trackX + trackW, trackY + trackH)
		glColor(0.18, 0.35, 0.48, 0.40)
		glRect(trackX, trackY, trackX + 1 * uiScale, trackY + trackH)
		glRect(trackX + trackW - 1 * uiScale, trackY, trackX + trackW, trackY + trackH)

		local thumbColor = UI_COLORS.accent
		glColor(thumbColor[1], thumbColor[2], thumbColor[3], 0.90)
		glRect(trackX + 1 * uiScale, thumbY, trackX + trackW - 1 * uiScale, thumbY + thumbH)
		glColor(1, 1, 1, 0.35)
		glRect(trackX + 1 * uiScale, thumbY + thumbH - 1 * uiScale, trackX + trackW - 1 * uiScale, thumbY + thumbH)
	end

	-- Cards
	cardAreas = {}
	local firstIndex = cardScroll * FACTORY_COLUMNS + 1
	local lastIndex = min(#cards, firstIndex + rows * FACTORY_COLUMNS - 1)
	local hoveredCardIndex = nil

	for i = firstIndex, lastIndex do
		local visibleIndex = i - firstIndex
		local col = visibleIndex % FACTORY_COLUMNS
		local row = floor(visibleIndex / FACTORY_COLUMNS)
		local cx = x + pad + col * (cardW + gap)
		local cy = cardAreaBottom + row * (cardH + gap)
		if isInRect(screenMouseX, screenMouseY, cx, cy, cx + cardW, cy + cardH) then
			hoveredCardIndex = i
		end
	end

	-- Draw non-hovered cards first
	for i = firstIndex, lastIndex do
		if i ~= hoveredCardIndex then
			local visibleIndex = i - firstIndex
			local col = visibleIndex % FACTORY_COLUMNS
			local row = floor(visibleIndex / FACTORY_COLUMNS)
			local cx = x + pad + col * (cardW + gap)
			local cy = cardAreaBottom + row * (cardH + gap)
			local queueControls = drawCard(cx, cy, cardW, cardH, cards[i], true, i, #cards, 1.0)
			cardAreas[#cardAreas + 1] = {
				x1 = cx, x2 = cx + cardW, y1 = cy, y2 = cy + cardH, item = cards[i],
				minus = queueControls and queueControls.minus,
				plus = queueControls and queueControls.plus,
			}
		end
	end

	-- Draw hovered card LAST on top with 10% zoom pop-up
	if hoveredCardIndex then
		local i = hoveredCardIndex
		local visibleIndex = i - firstIndex
		local col = visibleIndex % FACTORY_COLUMNS
		local row = floor(visibleIndex / FACTORY_COLUMNS)
		local cx = x + pad + col * (cardW + gap)
		local cy = cardAreaBottom + row * (cardH + gap)
		local hoverScale = 1.10
		local zw = cardW * hoverScale
		local zh = cardH * hoverScale
		local zx = cx - (zw - cardW) * 0.5
		local zy = cy - (zh - cardH) * 0.5

		local queueControls = drawCard(zx, zy, zw, zh, cards[i], true, i, #cards, hoverScale)
		drawHoverGlow(zx, zy, zx + zw, zy + zh, UI_COLORS.accent or {0.38, 0.88, 1.0, 1.0})
		cardAreas[#cardAreas + 1] = {
			x1 = zx, x2 = zx + zw, y1 = zy, y2 = zy + zh, item = cards[i],
			minus = queueControls and queueControls.minus,
			plus = queueControls and queueControls.plus,
		}
	end

	if #cards == 0 then
		drawText(activeTier == 0 and "No factory units" or ("No T" .. activeTier .. " units"),
			x + panelW * 0.5, cardAreaBottom + cardH * 0.5, 14 * uiScale, {0.62, 0.70, 0.75, 1}, "oc")
	end
end


local function drawMenu()
	dragHandle = nil
	if not visible then return end
	if factoryMode then
		return drawFactoryMenu()
	end
	local x, y, panelW, panelH, cardW, cardH, gap, pad, categoryTabH, categoryAreaH, categoryTabGap, tierTabH, tabGap, rows, allRows, categoryRows, headerH, headerGap = panelMetrics()
	menuX, menuY, menuW, menuH = x, y, panelW, panelH

	local activeCategoryColor = CATEGORIES[categoryIndex(activeCategory)].color
	drawGlassRect(x, y, x + panelW, y + panelH, UI_COLORS.panel, UI_COLORS.panelBorder, activeCategoryColor)
	if SHOW_3D_MODELS and gl.UnitShape and (GL and GL.DEPTH_BUFFER_BIT) then
		gl.Clear((GL and GL.DEPTH_BUFFER_BIT))
	end

	drawTopHeaderBar(x, y, panelW, panelH, headerH, activeCategoryColor or {0.38, 0.88, 1.0, 1.0})

	local categoryTabY = y + pad
	local tierTabY = categoryTabY + categoryAreaH + tabGap
	local cardAreaBottom = tierTabY + tierTabH

	-- 1. Category Tabs (Draw underneath cards so hovered card floats above tabs)
	tabs = {}
	local categoryTabInsetX = 8 * uiScale
	local categoryTabGapX = 14 * uiScale
	local tabW = (panelW - 2 * categoryTabInsetX - (CATEGORY_COLUMNS - 1) * categoryTabGapX) / CATEGORY_COLUMNS
	for i, category in ipairs(CATEGORIES) do
		local col = (i - 1) % CATEGORY_COLUMNS
		local row = floor((i - 1) / CATEGORY_COLUMNS)
		local tx = x + categoryTabInsetX + col * (tabW + categoryTabGapX)
		local ty = categoryTabY + (categoryRows - row - 1) * (categoryTabH + categoryTabGap)
		local selected = category.key == activeCategory
		drawGlassRect(tx + 1 * uiScale, ty, tx + tabW - 1 * uiScale, ty + categoryTabH,
			selected and UI_COLORS.tabSelected or UI_COLORS.tab, UI_COLORS.cardBorder, selected and category.color or nil)
		local tabFontSize = (#category.label > 18 and 8 or (#category.label > 12 and 9 or 10)) * uiScale
		local labelX = tx + 13 * uiScale
		local keyX = tx + tabW - 13 * uiScale
		local labelMaxWidth = max(1, keyX - labelX - 18 * uiScale)
		local label = fitTitleToWidth(category.tabLabel or category.label, labelMaxWidth, tabFontSize)
		local baseline = ty + 8 * uiScale
		drawText(label, labelX, baseline, tabFontSize, selected and {0.95, 0.97, 1, 1} or {0.58, 0.64, 0.68, 1}, "o")
		drawText(upper(category.hotkey), keyX, baseline, 9 * uiScale, category.color, "or")
		tabs[#tabs + 1] = {x1 = tx, x2 = tx + tabW, y1 = ty, y2 = ty + categoryTabH, key = category.key}
	end
	tierTabs = {}

	-- 2. Scrollbar (Draw underneath cards so hovered card floats above scrollbar)
	if allRows > rows then
		local trackW = 5 * uiScale
		local trackX = x + panelW - trackW - 3 * uiScale
		local trackY = cardAreaBottom
		local trackH = rows * cardH + (rows - 1) * gap
		local thumbH = max(22 * uiScale, trackH * rows / allRows)
		local thumbY = trackY + (trackH - thumbH) * (cardScroll / maxCardScroll)
		glColor(0.010, 0.022, 0.035, 0.80)
		glRect(trackX, trackY, trackX + trackW, trackY + trackH)
		glColor(0.18, 0.35, 0.48, 0.40)
		glRect(trackX, trackY, trackX + 1 * uiScale, trackY + trackH)
		glRect(trackX + trackW - 1 * uiScale, trackY, trackX + trackW, trackY + trackH)

		local thumbColor = activeCategoryColor or UI_COLORS.accent
		glColor(thumbColor[1], thumbColor[2], thumbColor[3], 0.90)
		glRect(trackX + 1 * uiScale, thumbY, trackX + trackW - 1 * uiScale, thumbY + thumbH)
		glColor(1, 1, 1, 0.35)
		glRect(trackX + 1 * uiScale, thumbY + thumbH - 1 * uiScale, trackX + trackW - 1 * uiScale, thumbY + thumbH)
	end

	-- 3. Cards
	cardAreas = {}
	local firstIndex = cardScroll * CARD_COLUMNS + 1
	local lastIndex = min(#cards, firstIndex + rows * CARD_COLUMNS - 1)
	local hoveredCardIndex = nil

	for i = firstIndex, lastIndex do
		local visibleIndex = i - firstIndex
		local col = visibleIndex % CARD_COLUMNS
		local row = floor(visibleIndex / CARD_COLUMNS)
		local cx = x + pad + col * (cardW + gap)
		local cy = cardAreaBottom + row * (cardH + gap)
		if isInRect(screenMouseX, screenMouseY, cx, cy, cx + cardW, cy + cardH) then
			hoveredCardIndex = i
		end
	end

	-- Draw non-hovered cards first
	for i = firstIndex, lastIndex do
		if i ~= hoveredCardIndex then
			local visibleIndex = i - firstIndex
			local col = visibleIndex % CARD_COLUMNS
			local row = floor(visibleIndex / CARD_COLUMNS)
			local cx = x + pad + col * (cardW + gap)
			local cy = cardAreaBottom + row * (cardH + gap)
			drawCard(cx, cy, cardW, cardH, cards[i], false, i, #cards, 1.0)
			cardAreas[#cardAreas + 1] = {x1 = cx, x2 = cx + cardW, y1 = cy, y2 = cy + cardH, item = cards[i]}
		end
	end

	-- Draw hovered card LAST on top with 10% zoom pop-up
	if hoveredCardIndex then
		local i = hoveredCardIndex
		local visibleIndex = i - firstIndex
		local col = visibleIndex % CARD_COLUMNS
		local row = floor(visibleIndex / CARD_COLUMNS)
		local cx = x + pad + col * (cardW + gap)
		local cy = cardAreaBottom + row * (cardH + gap)
		local hoverScale = 1.10
		local zw = cardW * hoverScale
		local zh = cardH * hoverScale
		local zx = cx - (zw - cardW) * 0.5
		local zy = cy - (zh - cardH) * 0.5

		drawCard(zx, zy, zw, zh, cards[i], false, i, #cards, hoverScale)
		drawHoverGlow(zx, zy, zx + zw, zy + zh, activeCategoryColor or {0.38, 0.88, 1.0, 1.0})
		cardAreas[#cardAreas + 1] = {x1 = zx, x2 = zx + zw, y1 = zy, y2 = zy + zh, item = cards[i]}
	end

	if #cards == 0 then
		local hasAny = false
		for _, cat in ipairs(CATEGORIES) do
			if #(availableByCategory[cat.key] or {}) > 0 then hasAny = true break end
		end
		local msg = hasAny and (activeTier == 0 and "No units in this tab" or ("No T" .. activeTier .. " units")) or "Select Commander or Builder"
		drawText(msg, x + panelW * 0.5, cardAreaBottom + cardH * 0.5, 13 * uiScale, {0.62, 0.78, 0.88, 1}, "oc")
	end
end

function widget:Initialize()
	installBuildmenuBridge()

	widget:ViewResize()
	refreshStrategicIcons()
	disableStockBuildWidgets()
	autoSelectCommanderIfNoneSelected()
	dirty = true
	refresh()

	-- Directly re-initialize Info widget in memory so it captures WG.buildmenu.getOrder()
	-- without toggling widgets or altering BYAR.lua!
	if widgetHandler and widgetHandler.FindWidget then
		local infoWidget = widgetHandler:FindWidget("Info")
		if infoWidget and infoWidget.Initialize then
			pcall(infoWidget.Initialize, infoWidget)
		end
		local orderWidget = widgetHandler:FindWidget("Order menu")
		if orderWidget and orderWidget.ViewResize then
			pcall(orderWidget.ViewResize, orderWidget)
		end
	end
end

function widget:Shutdown()
	restoreStockBuildWidgets()
end

function widget:GetConfigData()
	return {
		panelOffsetX = panelOffsetX,
		panelOffsetY = panelOffsetY,
	}
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then return end
	if type(data.panelOffsetX) == "number" then panelOffsetX = data.panelOffsetX end
	if type(data.panelOffsetY) == "number" then panelOffsetY = data.panelOffsetY end
end

function widget:ViewResize()
	updateUIScale()
	cardScroll = 0
	if WG.fonts then
		font = WG.fonts.getFont(2, 1.0)
		smallFont = WG.fonts.getFont(2, 0.85)
	end
	clampPanelPosition()
	dirty = true
	refresh()
end

function widget:SelectionChanged()
	pinnedCompareItem = nil
	pinnedCompareItemB = nil
	activeTier = 0
	cardScroll = 0
	dirty = true
	refresh()
end

function widget:CommandsChanged()
	pinnedCompareItem = nil
	pinnedCompareItemB = nil
	dirty = true
	refresh()
end

function widget:GameStart()
	autoSelectCommanderIfNoneSelected()
	dirty = true
	refresh()
end

function widget:UnitCreated(unitID, unitDefID, teamID)
	if teamID == (spGetMyTeamID and spGetMyTeamID()) then
		dirty = true
	end
end

function widget:UnitDestroyed(unitID)
	if etaState[unitID] then etaState[unitID] = nil end
	dirty = true
end

function widget:PlayerChanged()
	dirty = true
	refresh()
end

function widget:TeamChanged()
	dirty = true
	refresh()
end

local function markFactoryQueueDirty(unitID)
	local defID = unitID and spGetUnitDefID and spGetUnitDefID(unitID)
	local def = defID and UnitDefs[defID]
	if def and def.isFactory then dirty = true end
end

function widget:UnitCommand(unitID)
	markFactoryQueueDirty(unitID)
end

function widget:UnitCmdDone(unitID)
	markFactoryQueueDirty(unitID)
end

function widget:UnitFromFactory(_, _, _, factoryID)
	markFactoryQueueDirty(factoryID)
end

function widget:Update()
	disableStockBuildWidgets()

	-- Check pending build command activation (e.g. when commander was auto-selected on click)
	if pendingBuildUnitDefID then
		local alt, ctrl, meta, shift = false, false, false, false
		if spGetModKeyState then
			alt, ctrl, meta, shift = spGetModKeyState()
		end
		local commandIndex = commandIndexForUnitDef(pendingBuildUnitDefID)
		if not commandIndex and spGetCmdDescIndex then
			commandIndex = spGetCmdDescIndex(-pendingBuildUnitDefID)
		end
		if not commandIndex and spGetUnitCmdDescs then
			local comID = getMyCommanderUnitID()
			if comID then
				local descs = spGetUnitCmdDescs(comID)
				if descs then
					for i = 1, #descs do
						local cmd = descs[i]
						if cmd and cmd.id == -pendingBuildUnitDefID then
							commandIndex = i
							break
						end
					end
				end
			end
		end
		if commandIndex and spSetActiveCommand then
			spSetActiveCommand(commandIndex, 1, true, false, alt or false, ctrl or false, meta or false, shift or false)
			pendingBuildUnitDefID = nil
			dirty = true
		end
	end

	-- If in pregame, check if faction/startUnit changed so the build options update immediately
	if isPregameState() then
		local myTeamID = spGetMyTeamID and spGetMyTeamID() or (Spring.GetLocalTeamID and Spring.GetLocalTeamID())
		local curStartUnit = myTeamID and Spring.GetTeamRulesParam and Spring.GetTeamRulesParam(myTeamID, "startUnit")
		if curStartUnit and curStartUnit ~= lastPregameStartUnit then
			lastPregameStartUnit = curStartUnit
			dirty = true
			refresh()
		end
	end

	local currentSysScale = getSystemUIScale()
	if currentSysScale ~= lastSysScale then
		lastSysScale = currentSysScale
		updateUIScale()
		dirty = true
	end
	local now = os.clock()
	local rotationSpan = MODEL_ROTATION_LIMIT * 2
	local rotationCycle = rotationSpan * 2
	local phase = (now * MODEL_ROTATION_SPEED + MODEL_ROTATION_LIMIT) % rotationCycle
	local offset = phase <= rotationSpan and phase or (rotationCycle - phase)
	modelRotation = MODEL_FRONT_YAW + offset - MODEL_ROTATION_LIMIT

	local actionTotal = 0
	for i = 1, #MODEL_ACTIONS do
		actionTotal = actionTotal + MODEL_ACTIONS[i].duration
	end
	local actionClock = actionTotal > 0 and (now % actionTotal) or 0
	local actionStart = 0
	local action = MODEL_ACTIONS[1]
	for i = 1, #MODEL_ACTIONS do
		local candidate = MODEL_ACTIONS[i]
		if actionClock < actionStart + candidate.duration then
			action = candidate
			break
		end
		actionStart = actionStart + candidate.duration
	end
	modelActionName = action.name
	local actionPhase = action.duration > 0 and (actionClock - actionStart) / action.duration or 0
	local waveCycles = action.waveCycles or 1
	local actionWave = sin(actionPhase * pi * 2 * waveCycles)
	modelActionBob = action.bob * actionWave
	modelActionTilt = action.tilt * actionWave
	modelActionYaw = action.sway * actionWave
	modelActionScale = 1 + (action.scalePulse or 0) * abs(actionWave)
	if dirty or now - lastRefresh >= REFRESH_SECONDS then
		lastRefresh = now
		refresh()
	end
end


function widget:IsAbove(x, y)
	if not visible then return false end
	screenMouseX = x
	screenMouseY = y
	return isInRect(x, y, menuX, menuY, menuX + menuW, menuY + menuH)
end

function widget:GetTooltip(x, y)
	if not visible then return nil end
	local item = nil
	if cardAreas then
		for i = 1, #cardAreas do
			local area = cardAreas[i]
			if x >= area.x1 and x <= area.x2 and y >= area.y1 and y <= area.y2 then
				item = area.item
				break
			end
		end
	end
	if not item and hoveredItem then
		item = hoveredItem
	end

	if item and item.unitDefID then
		local def = UnitDefs[item.unitDefID]
		if def then
			local name = def.translatedHumanName or def.humanName or def.name or "Unit"
			local tip = def.tooltip or ""
			if tip ~= "" then
				return "Build: " .. name .. " - " .. tip
			else
				return "Build: " .. name
			end
		end
	end
	return nil
end

local function getUnitDescription(def)
	if not def then return "Combat Unit" end
	local cp = def.customParams or {}
	local desc = cp.description
	if desc and desc ~= "" and lower(desc) ~= "weapon" and lower(desc) ~= "unit" then
		return desc
	end
	if cp.helptext and cp.helptext ~= "" then
		return cp.helptext
	end
	return unitRoleLabel(def) or "Combat Unit"
end

local function getDetailedUnitIntel(def, item)
	if not def then return nil end
	local intel = {}
	local cp = def.customParams or {}

	-- 1. Costs (Metal / Energy / BuildTime)
	local m = math.floor(def.metalCost or (item and item.metal) or 0)
	local e = math.floor(def.energyCost or (item and item.energy) or 0)
	local bt = math.floor(def.buildTime or 0)
	intel.cost = { metal = m, energy = e, buildTime = bt }

	-- 2. Movement / Speed / Accel / Turn / Terrain
	local spd = def.speed and def.speed > 0 and (math.floor(def.speed * 10) / 10) or 0
	local accel = def.maxAcc and (math.floor(def.maxAcc * 3000) / 10) or 0
	local turn = def.turnRate and math.floor(def.turnRate / 182) or 0
	local maxSlope = def.maxSlope and math.floor(def.maxSlope * 100) or nil
	local waterDepth = def.maxWaterDepth and math.floor(def.maxWaterDepth) or nil
	intel.move = { speed = spd, accel = accel, turn = turn, maxSlope = maxSlope, waterDepth = waterDepth, isBuilding = def.isBuilding }

	-- 3. Build Power & Nano Range
	intel.buildSpeed = (def.buildSpeed and def.buildSpeed > 0) and math.floor(def.buildSpeed) or nil
	intel.buildDistance = (def.buildDistance and def.buildDistance > 0) and math.floor(def.buildDistance) or nil

	-- 4. Line of Sight & AirLoS
	local los = math.floor(def.losRadius or 0)
	local airLos = math.floor(def.airLosRadius or (los * 1.5))
	intel.los = { los = los, airLos = airLos }

	-- 5. Armor, EMP, AutoHeal & HP
	intel.armor = "classdefault"
	if def.armorType and Game and Game.armorTypes and Game.armorTypes[def.armorType] then
		intel.armor = "class" .. tostring(Game.armorTypes[def.armorType])
	elseif def.armorType then
		intel.armor = "class" .. tostring(def.armorType)
	end
	intel.maxHP = math.floor(def.health or 0)
	intel.emp = (def.paralyzeDamageCost and def.paralyzeDamageCost <= 0) and "Immune" or (cp.immune_to_emp and "Immune" or nil)
	intel.autoHeal = (def.autoHeal and def.autoHeal > 0 and math.floor(def.autoHeal * 30)) or (def.idleAutoHeal and def.idleAutoHeal > 0 and math.floor(def.idleAutoHeal * 30)) or nil
	intel.transport = def.transportCapacity and def.transportCapacity > 0 and {
		capacity = def.transportCapacity,
		mass = def.transportMass and (def.transportMass > 5000 and "Heavy" or (def.transportMass > 1000 and "Medium" or "Light")) or "Light"
	} or nil

	-- 6. Economy, Generation & Storage
	intel.energyMake = def.energyMake and def.energyMake > 0 and math.floor(def.energyMake) or nil
	intel.metalMake = def.metalMake and def.metalMake > 0 and (math.floor(def.metalMake * 10) / 10) or nil
	intel.extractsMetal = def.extractsMetal and def.extractsMetal > 0 or nil
	intel.windMin = def.windEnergyMin and math.floor(def.windEnergyMin) or nil
	intel.windMax = def.windEnergyMax and math.floor(def.windEnergyMax) or nil
	intel.energyUpkeep = def.energyUpkeep and def.energyUpkeep > 0 and math.floor(def.energyUpkeep) or nil
	intel.metalStorage = def.metalStorage and def.metalStorage > 50 and math.floor(def.metalStorage) or nil
	intel.energyStorage = def.energyStorage and def.energyStorage > 50 and math.floor(def.energyStorage) or nil

	-- 7. Sensors, Stealth & Cloak
	intel.radarRadius = def.radarRadius and def.radarRadius > 0 and math.floor(def.radarRadius) or nil
	intel.sonarRadius = def.sonarRadius and def.sonarRadius > 0 and math.floor(def.sonarRadius) or nil
	intel.jammerRadius = def.jammerRadius and def.jammerRadius > 0 and math.floor(def.jammerRadius) or nil
	intel.sonarJamRadius = def.sonarJamRadius and def.sonarJamRadius > 0 and math.floor(def.sonarJamRadius) or nil
	intel.seismicRadius = def.seismicRadius and def.seismicRadius > 0 and math.floor(def.seismicRadius) or nil
	if def.canCloak then
		intel.cloak = {
			staticCost = math.floor(def.cloakCost or 0),
			movingCost = math.floor(def.cloakCostMoving or (def.cloakCost or 0) * 2),
			distance = math.floor(def.minCloakDistance or 60)
		}
	end

	-- 8. Abilities
	local abList = {}
	if cp.canmanualfire or def.canManualFire then abList[#abList + 1] = "Manual Fire" end
	if def.canStockpile then abList[#abList + 1] = "Stockpile" end
	if cp.is_paralyzer or cp.paralyzer then abList[#abList + 1] = "Paralyzer" end
	if def.canAssist or def.canRepair or def.canReclaim or def.canResurrect then
		local bAbs = {}
		if def.canAssist then bAbs[#bAbs + 1] = "Assist" end
		if def.canRepair then bAbs[#bAbs + 1] = "Repair" end
		if def.canReclaim then bAbs[#bAbs + 1] = "Reclaim" end
		if def.canResurrect then bAbs[#bAbs + 1] = "Resurrect" end
		abList[#abList + 1] = table.concat(bAbs, "/")
	end
	if def.canCloak then abList[#abList + 1] = "Cloak" end
	if def.stealth then abList[#abList + 1] = "Stealth" end
	if def.radarRadius and def.radarRadius > 0 then abList[#abList + 1] = "Radar" end
	if def.sonarRadius and def.sonarRadius > 0 then abList[#abList + 1] = "Sonar" end
	if def.jammerRadius and def.jammerRadius > 0 then abList[#abList + 1] = "Jammer" end
	if #abList == 0 then
		abList[#abList + 1] = def.isBuilding and "Structure" or "Combat"
	end
	intel.abilities = table.concat(abList, ", ")

	-- 9. Weapons Breakdown
	intel.weapons = {}
	local totalDPS = 0
	local totalBurst = 0

	if def.weapons and #def.weapons > 0 then
		for i = 1, #def.weapons do
			local w = def.weapons[i]
			local wDef = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
			if wDef then
				local wItem = {}
				wItem.count = 1
				wItem.name = wDef.description or wDef.name or ("Weapon " .. i)
				local reload = wDef.reload or 1
				if reload < 0.05 then reload = 0.05 end
				wItem.reload = math.floor(reload * 100 + 0.5) / 100
				wItem.range = math.floor(wDef.range or 0)
				wItem.aoe = math.floor(wDef.damageAreaOfEffect or 0)
				wItem.edge = math.floor((wDef.edgeEffectiveness or 0.15) * 100)
				wItem.projSpeed = wDef.projectilespeed and math.floor(wDef.projectilespeed * 30) or nil
				wItem.isShield = wDef.isShield or (wDef.shieldPower and wDef.shieldPower > 0)
				if wItem.isShield then
					wItem.shieldPower = math.floor(wDef.shieldPower or wDef.shieldMax or 1000)
					wItem.shieldRegen = math.floor(wDef.shieldPowerRegen or 10)
				end
				if wDef.paralyzer then
					wItem.paralyzeTime = math.floor(wDef.paralyzeTime or 8)
				end

				-- Damage calculation
				local damage = 0
				if wDef.customParams and wDef.customParams.damagew1 then
					damage = tonumber(wDef.customParams.damagew1) or 0
				elseif wDef.damages then
					damage = tonumber(wDef.damages[1] or wDef.damages[0] or wDef.damages.default) or 0
				end
				local burst = tonumber(wDef.salvoSize or wDef.projectiles or 1) or 1
				local singleBurst = math.floor(damage * burst)
				local dps = math.floor((damage * burst) / reload + 0.5)
				wItem.dps = dps
				wItem.burst = singleBurst

				-- Trajectory type
				if wDef.waterWeapon or wDef.submissile then
					wItem.traj = "Torpedo"
				elseif wDef.canAttackAir and not wDef.canAttackGround then
					wItem.traj = "Anti-Air"
				elseif wDef.highTrajectory == 1 or (wDef.trajectoryHeight and wDef.trajectoryHeight > 0.8) then
					wItem.traj = "High Arc (Artillery)"
				else
					wItem.traj = "Direct Fire"
				end

				-- Weapon firing cost
				local mCostPerShot = tonumber(wDef.metalCost or 0) or 0
				local eCostPerShot = tonumber(wDef.energyCost or 0) or 0
				if eCostPerShot > 0 or mCostPerShot > 0 then
					wItem.shotCost = string.format("-%d E, -%d M/shot", eCostPerShot, mCostPerShot)
				end

				totalDPS = totalDPS + dps
				totalBurst = totalBurst + singleBurst
				intel.weapons[#intel.weapons + 1] = wItem
			end
		end
	end

	-- 10. Death explosions & Self destruct
	if def.deathExplosion and WeaponDefs and WeaponDefs[def.deathExplosion] then
		local wDef = WeaponDefs[def.deathExplosion]
		local damage = tonumber(wDef.damages and (wDef.damages[1] or wDef.damages[0] or wDef.damages.default) or 0) or 0
		intel.deathExplosion = {
			name = "Death Explosion",
			aoe = math.floor(wDef.damageAreaOfEffect or 18),
			edge = math.floor((wDef.edgeEffectiveness or 0) * 100),
			burst = math.floor(damage)
		}
	end
	if def.selfDExplosion and WeaponDefs and WeaponDefs[def.selfDExplosion] then
		local wDef = WeaponDefs[def.selfDExplosion]
		local damage = tonumber(wDef.damages and (wDef.damages[1] or wDef.damages[0] or wDef.damages.default) or 0) or 0
		intel.selfDestruct = {
			name = "Self Destruct",
			aoe = math.floor(wDef.damageAreaOfEffect or 30),
			edge = math.floor((wDef.edgeEffectiveness or 0) * 100),
			burst = math.floor(damage)
		}
	end

	intel.totalDPS = totalDPS
	intel.totalBurst = totalBurst
	return intel
end

local function getNumericDiff(numA, numB, lowerIsBetter, unitSuffix)
	if not numA or not numB then return nil, nil end
	local nA = tonumber(tostring(numA):match("[%d%.]+"))
	local nB = tonumber(tostring(numB):match("[%d%.]+"))
	if not nA or not nB then return nil, nil end
	local diff = nB - nA
	if abs(diff) < 0.001 then return nil, nil end
	local isBetter = (diff > 0)
	if lowerIsBetter then isBetter = (diff < 0) end
	local sign = diff > 0 and "+" or ""
	local diffFormatted
	if abs(diff) >= 10000 then
		diffFormatted = string.format("%s%.1fk", sign, diff / 1000)
	elseif abs(diff) >= 1000 then
		diffFormatted = string.format("%s%.2fk", sign, diff / 1000)
	elseif abs(diff) >= 10 then
		diffFormatted = string.format("%s%d", sign, math.floor(diff + 0.5))
	else
		diffFormatted = string.format("%s%.1f", sign, diff)
	end
	if unitSuffix and unitSuffix ~= "" then diffFormatted = diffFormatted .. unitSuffix end
	local color = isBetter and {0.30, 0.95, 0.55, 1.0} or {0.98, 0.28, 0.28, 1.0}
	return "(" .. diffFormatted .. ")", color
end

local function drawStatPill(x, y, w, pillH, meterH, label, valStr, barColor, fillLevel, maxTicks, diffStr, diffColor)
	local meterTicks = maxTicks or 20
	local activeTicks = fillLevel or 0
	local hasNumbers = tostring(valStr):match("%d") ~= nil
	if not hasNumbers then activeTicks = 0 end
	local pillY = y + meterH + 2 * uiScale
	-- Translucent Dark Background
	glColor(0.015, 0.028, 0.042, 0.75)
	glRect(x, pillY, x + w, pillY + pillH)
	glColor(0.35, 0.60, 0.80, 0.50)
	glRect(x, pillY, x + w, pillY + 1 * uiScale)
	glRect(x, pillY + pillH - 1 * uiScale, x + w, pillY + pillH)
	glRect(x, pillY, x + 1 * uiScale, pillY + pillH)
	glRect(x + w - 1 * uiScale, pillY, x + w, pillY + pillH)
	-- Left glowing indicator pip matching the stat category color
	if activeTicks > 0 then
		glColor(barColor[1], barColor[2], barColor[3], 0.95)
	else
		glColor(0.60, 0.75, 0.90, 0.40)
	end
	glRect(x, pillY, x + 3.5 * uiScale, pillY + pillH)
	-- Label (Left)
	local fontSize = 9.0 * uiScale
	gl.Scissor(floor(x + 5 * uiScale), floor(pillY), max(1, floor(w * 0.45)), max(1, floor(pillH)))
	drawText(label, x + 8 * uiScale, pillY + pillH * 0.5, fontSize, {0.82, 0.90, 0.98, 0.95}, "vo")
	gl.Scissor(false)
	-- Values (Right)
	local rightX = x + w - 7 * uiScale
	if diffStr and diffStr ~= "" then
		local diffFont = fontSize * 0.88
		local diffW = getTextPixelWidth(diffStr, diffFont)
		gl.Scissor(floor(x + w * 0.35), floor(pillY), max(1, floor(w * 0.64)), max(1, floor(pillH)))
		drawText(diffStr, rightX, pillY + pillH * 0.5, diffFont, diffColor or {0.30, 0.95, 0.55, 1.0}, "vro")
		drawText(valStr, rightX - diffW - 5 * uiScale, pillY + pillH * 0.5, fontSize, {1.0, 1.0, 1.0, 1.0}, "vro")
		gl.Scissor(false)
	else
		gl.Scissor(floor(x + w * 0.45), floor(pillY), max(1, floor(w * 0.54)), max(1, floor(pillH)))
		drawText(valStr, rightX, pillY + pillH * 0.5, fontSize, {1.0, 1.0, 1.0, 1.0}, "vro")
		gl.Scissor(false)
	end
	local tickGap = 1.2 * uiScale
	local tickW = (w - (meterTicks - 1) * tickGap) / meterTicks
	for t = 1, meterTicks do
		local tx = x + (t - 1) * (tickW + tickGap)
		if t <= activeTicks then
			glColor(barColor[1], barColor[2], barColor[3], 0.92)
			glRect(tx, y, tx + tickW, y + meterH)
			glColor(1, 1, 1, 0.25)
			glRect(tx, y + meterH - 1 * uiScale, tx + tickW, y + meterH)
		else
			-- Inactive ticks: Solid dark slot
			glColor(0.040, 0.065, 0.090, 0.85)
			glRect(tx, y, tx + tickW, y + meterH)
			glColor(0.30, 0.55, 0.75, 0.35)
			glRect(tx, y, tx + tickW, y + 1 * uiScale)
		end
	end
end

local function calcStatTicks(val, maxBenchmark)
	if not val or val <= 0 then return 0 end
	local ratio = val / (maxBenchmark or 100)
	return min(20, max(1, math.floor(ratio * 20 + 0.5)))
end

local function buildUnitIntelRows(intel, def, item)
	if not intel or not def then return nil end
	local primaryWeapon = (intel.weapons and intel.weapons[1])
	local cEmerald    = {0.30, 0.95, 0.55}
	local cMint       = {0.25, 0.92, 0.78}
	local cShield     = {0.20, 0.75, 1.00}
	local cRuby       = {0.98, 0.28, 0.28}
	local cCoral      = {1.00, 0.45, 0.22}
	local cAmber      = {0.98, 0.78, 0.18}
	local cMagenta    = {0.98, 0.35, 0.72}
	local cFlame      = {1.00, 0.55, 0.15}
	local cCerulean   = {0.35, 0.78, 1.00}
	local cCopper     = {0.95, 0.65, 0.25}
	local cLimeGold   = {0.85, 0.95, 0.20}
	local cSpring     = {0.60, 0.95, 0.30}
	local cMetalCyan  = {0.38, 0.85, 0.95}
	local cBlood      = {0.95, 0.32, 0.15}
	local cPurple     = {0.75, 0.50, 1.00}
	local cAquamarine = {0.25, 0.88, 0.65}
	local cCyberSky   = {0.28, 0.82, 1.00}
	local cCobalt     = {0.25, 0.60, 0.98}
	local cOrchid     = {0.88, 0.45, 0.95}
	local cLavender   = {0.70, 0.60, 0.95}
	local cAzure      = {0.20, 0.68, 1.00}
	local cIceAqua    = {0.35, 0.90, 0.92}
	local cSage       = {0.55, 0.85, 0.45}
	local cSapphire   = {0.40, 0.70, 0.95}
	local cLime       = {0.62, 0.94, 0.25}
	local cTurquoise  = {0.25, 0.88, 0.88}
	local cCrimson    = {0.95, 0.32, 0.15}
	local cFireRed    = {1.00, 0.18, 0.18}
	local cIndustrial = {1.00, 0.55, 0.18}
	local cGoldVolt   = {1.00, 0.85, 0.22}
	local cRose       = {0.95, 0.42, 0.48}
	local cMutedSlate = {0.45, 0.60, 0.75}
	local rows = {}
	local rowMap = {}
	local function addRow(key, label, val, numVal, color, ticks, lowerIsBetter, unitSuffix)
		local r = { key = key, label = label, val = tostring(val), numVal = numVal, color = color, ticks = ticks or 0, lowerIsBetter = lowerIsBetter or false, unitSuffix = unitSuffix or "", }
		rows[#rows + 1] = r
		rowMap[key] = r
	end
	local hpVal = intel.maxHP or 0
	addRow("health", "Health", hpVal, hpVal, cEmerald, calcStatTicks(hpVal, 25000), false)
	if intel.autoHeal and intel.autoHeal > 0 then addRow("autoHeal", "Auto-Heal", "+" .. intel.autoHeal .. " HP/s", intel.autoHeal, cMint, calcStatTicks(intel.autoHeal, 100), false, " HP/s") end
	if primaryWeapon and primaryWeapon.isShield then
		addRow("shield", "Shield Max", formatCost(primaryWeapon.shieldPower), primaryWeapon.shieldPower, cShield, calcStatTicks(primaryWeapon.shieldPower, 12000), false)
		if primaryWeapon.shieldRegen and primaryWeapon.shieldRegen > 0 then addRow("shieldRegen", "Shield Regen", "+" .. primaryWeapon.shieldRegen .. "/s", primaryWeapon.shieldRegen, cShield, calcStatTicks(primaryWeapon.shieldRegen, 100), false, "/s") end
	end
	local isDPS = (intel.totalDPS and intel.totalDPS > 0)
	local dpsVal = isDPS and intel.totalDPS or (intel.buildSpeed and intel.buildSpeed > 0 and intel.buildSpeed)
	if dpsVal then addRow(isDPS and "dps" or "buildPower", isDPS and "DPS" or "Build Power", dpsVal, dpsVal, isDPS and cRuby or cLimeGold, calcStatTicks(dpsVal, isDPS and 2500 or 500), false) end
	if primaryWeapon and primaryWeapon.burst and primaryWeapon.burst > 0 and primaryWeapon.burst ~= (primaryWeapon.dps or 0) then addRow("burst", "Burst Dmg", primaryWeapon.burst, primaryWeapon.burst, cCoral, calcStatTicks(primaryWeapon.burst, 3500), false) end
	local rangeVal = (primaryWeapon and primaryWeapon.range) or (def.maxWeaponRange and math.floor(def.maxWeaponRange))
	if rangeVal and rangeVal > 0 then addRow("range", "Range", rangeVal, rangeVal, cAmber, calcStatTicks(rangeVal, 1600), false) end
	if primaryWeapon and primaryWeapon.reload and primaryWeapon.reload > 0 then
		local rRatio = max(0.05, 1 - (primaryWeapon.reload / 6.0))
		local rTicks = min(20, max(1, math.floor(rRatio * 20 + 0.5)))
		addRow("reload", "Reload", string.format("%.1fs", primaryWeapon.reload), primaryWeapon.reload, cMagenta, rTicks, true, "s")
	end
	if primaryWeapon and primaryWeapon.aoe and primaryWeapon.aoe > 0 then addRow("aoe", "AoE Blast", primaryWeapon.aoe, primaryWeapon.aoe, cFlame, calcStatTicks(primaryWeapon.aoe, 300), false) end
	if primaryWeapon and primaryWeapon.projSpeed and primaryWeapon.projSpeed > 0 then addRow("projSpeed", "Proj Speed", primaryWeapon.projSpeed .. " el/s", primaryWeapon.projSpeed, cCerulean, calcStatTicks(primaryWeapon.projSpeed, 1200), false, " el/s") end
	if #intel.weapons > 1 then
		local w2 = intel.weapons[2]
		addRow("weapon2", "Weapon 2", w2.dps .. " DPS (" .. w2.range .. "r)", w2.dps, cCopper, calcStatTicks(w2.dps, 1500), false)
	end
	if intel.windMin and intel.windMax then addRow("windGen", "Wind Gen", intel.windMin .. "-" .. intel.windMax .. " E/s", intel.windMax, cSpring, calcStatTicks(intel.windMax, 30), false, " E/s")
	elseif intel.energyMake and intel.energyMake > 0 then addRow("energyGen", "Energy Gen", "+" .. formatCost(intel.energyMake) .. "/s", intel.energyMake, cLimeGold, calcStatTicks(intel.energyMake, 3500), false, "/s") end
	if intel.extractsMetal or (intel.metalMake and intel.metalMake > 0) then
		local isExt = intel.extractsMetal
		local mStr = isExt and "Extractor" or ("+" .. formatCost(intel.metalMake) .. "/s")
		local mTicks = isExt and 0 or calcStatTicks(intel.metalMake, 25)
		addRow("metalGen", "Metal Gen", mStr, intel.metalMake or 0, cMetalCyan, mTicks, false, "/s")
	end
	if intel.energyUpkeep and intel.energyUpkeep > 0 then addRow("energyDrain", "Energy Drain", "-" .. intel.energyUpkeep .. " E/s", intel.energyUpkeep, cBlood, calcStatTicks(intel.energyUpkeep, 500), true, " E/s") end
	if intel.metalStorage or intel.energyStorage then
		local sStr = (intel.metalStorage and (formatCost(intel.metalStorage) .. " M ") or "") .. (intel.energyStorage and (formatCost(intel.energyStorage) .. " E") or "")
		local sVal = (intel.energyStorage or 0) + (intel.metalStorage or 0) * 10
		addRow("storage", "Storage", sStr, sVal, cPurple, calcStatTicks(sVal, 20000), false)
	end
	if intel.buildDistance and intel.buildDistance > 0 then addRow("nanoReach", "Nano Reach", intel.buildDistance .. " dist", intel.buildDistance, cAquamarine, calcStatTicks(intel.buildDistance, 250), false, " dist") end
	if intel.radarRadius and intel.radarRadius > 0 then addRow("radar", "Radar Range", intel.radarRadius, intel.radarRadius, cCyberSky, calcStatTicks(intel.radarRadius, 3500), false) end
	if intel.sonarRadius and intel.sonarRadius > 0 then addRow("sonar", "Sonar Range", intel.sonarRadius, intel.sonarRadius, cCobalt, calcStatTicks(intel.sonarRadius, 2500), false) end
	if intel.jammerRadius and intel.jammerRadius > 0 then addRow("jammer", "Jammer Range", intel.jammerRadius, intel.jammerRadius, cOrchid, calcStatTicks(intel.jammerRadius, 1000), false) end
	if intel.cloak then addRow("cloak", "Cloak Drain", intel.cloak.staticCost .. "/" .. intel.cloak.movingCost .. " E/s", intel.cloak.movingCost, cLavender, calcStatTicks(intel.cloak.movingCost, 30), true, " E/s") end
	if intel.move.speed > 0 and not intel.move.isBuilding then
		addRow("speed", "Speed", string.format("%.1f", intel.move.speed), intel.move.speed, cAzure, calcStatTicks(intel.move.speed, 120), false)
		if intel.move.turn and intel.move.turn > 0 then addRow("turnRate", "Turn Rate", intel.move.turn .. "°/s", intel.move.turn, cIceAqua, calcStatTicks(intel.move.turn, 150), false, "°/s") end
		if intel.move.maxSlope and intel.move.maxSlope > 0 then addRow("maxSlope", "Max Slope", intel.move.maxSlope .. "%", intel.move.maxSlope, cSage, calcStatTicks(intel.move.maxSlope, 60), false, "%") end
	end
	if intel.transport then addRow("transport", "Transport", intel.transport.capacity .. " (" .. intel.transport.mass .. ")", intel.transport.capacity, cSapphire, calcStatTicks(intel.transport.capacity, 16), false) end
	local losVal = intel.los.los or 0
	if losVal > 0 then
		addRow("sight", "Sight Range", losVal, losVal, cLime, calcStatTicks(losVal, 800), false)
		if intel.los.airLos and intel.los.airLos > losVal then addRow("airSight", "Air Sight", intel.los.airLos, intel.los.airLos, cTurquoise, calcStatTicks(intel.los.airLos, 800), false) end
	end
	if intel.deathExplosion and intel.deathExplosion.burst > 0 then addRow("deathBlast", "Death Blast", intel.deathExplosion.burst .. " dmg", intel.deathExplosion.burst, cCrimson, calcStatTicks(intel.deathExplosion.burst, 4000), false, " dmg") end
	if intel.selfDestruct and intel.selfDestruct.burst > 0 then addRow("selfDestruct", "Self-Destruct", intel.selfDestruct.burst .. " dmg", intel.selfDestruct.burst, cFireRed, calcStatTicks(intel.selfDestruct.burst, 4000), false, " dmg") end
	local mCost = formatCost(intel.cost.metal or 0)
	addRow("metalCost", "Metal Cost", mCost .. " M", intel.cost.metal or 0, cIndustrial, calcStatTicks(intel.cost.metal or 0, 10000), true, " M")
	local eCost = formatCost(intel.cost.energy or 0)
	addRow("energyCost", "Energy Cost", eCost .. " E", intel.cost.energy or 0, cGoldVolt, calcStatTicks(intel.cost.energy or 0, 70000), true, " E")
	local btSec = intel.cost.buildTime and (math.floor(intel.cost.buildTime / 100 + 0.5) .. "s") or "-"
	addRow("buildTime", "Build Time", btSec, intel.cost.buildTime and (intel.cost.buildTime / 100) or 0, cRose, calcStatTicks(intel.cost.buildTime and (intel.cost.buildTime / 100) or 0, 3500), true, "s")
	local rawArmor = intel.emp and "Immune" or intel.armor
	local armorClean = rawArmor:gsub("^class", "")
	armorClean = armorClean:sub(1,1):upper() .. armorClean:sub(2)
	addRow("armor", "Armor", armorClean, nil, cMutedSlate, 0)
	local abShort = (intel.abilities and intel.abilities ~= "") and intel.abilities:match("^[^,]+") or (def.isBuilding and "Structure" or "Combat")
	addRow("abilities", "Abilities", abShort, nil, cMutedSlate, 0)
	if primaryWeapon and primaryWeapon.traj and primaryWeapon.traj ~= "Direct Fire" then addRow("trajectory", "Trajectory", primaryWeapon.traj, nil, cMutedSlate, 0) end
	local sortedRows = {}
	for i = 1, #rows do if tostring(rows[i].val):match("%d") ~= nil then sortedRows[#sortedRows + 1] = rows[i] end end
	for i = 1, #rows do if tostring(rows[i].val):match("%d") == nil then sortedRows[#sortedRows + 1] = rows[i] end end
	return { rows = sortedRows, rowMap = rowMap, intel = intel, def = def, item = item, }
end

local function drawSingleUnitBox(boxX, boxY, boxW, boxH, headerH, pillH, meterH, stepY, padX, data, vsBadgeText, vsBadgeColor, baseDataForDiff)
	local def = data.def
	local item = data.item
	local rows = data.rows
	local activeCategoryColor = CATEGORIES[categoryIndex(activeCategory)].color or UI_COLORS.accent
	local themeColor = vsBadgeColor or activeCategoryColor
	-- Translucent Dark Glass Background
	drawGlassRect(boxX, boxY, boxX + boxW, boxY + boxH, {0.015, 0.025, 0.038, 0.76}, UI_COLORS.panelBorder, themeColor)
	local headerPad = 8 * uiScale
	local headerX = boxX + headerPad
	local headerW = boxW - headerPad * 2
	local headerY = boxY + boxH - 8 * uiScale - headerH
	-- Translucent Dark Header Bar
	glColor(0.020, 0.045, 0.070, 0.76)
	glRect(headerX, headerY, headerX + headerW, headerY + headerH)
	glColor(themeColor[1], themeColor[2], themeColor[3], 0.90)
	glRect(headerX, headerY + headerH - 1.5 * uiScale, headerX + headerW, headerY + headerH)
	glColor(0.35, 0.65, 0.85, 0.45)
	glRect(headerX, headerY, headerX + headerW, headerY + 1 * uiScale)
	glColor(0.35, 0.65, 0.85, 0.45)
	glRect(headerX, headerY, headerX + 1 * uiScale, headerY + headerH)
	glRect(headerX + headerW - 1 * uiScale, headerY, headerX + headerW, headerY + headerH)
	-- Left glowing indicator pip
	glColor(themeColor[1], themeColor[2], themeColor[3], 1.0)
	glRect(headerX + 8 * uiScale, headerY + 6 * uiScale, headerX + 11.5 * uiScale, headerY + headerH - 6 * uiScale)

	-- Unit Name (Natural Title Typography)
	local rawName = def.translatedHumanName or def.humanName or def.name or "Unit"
	local tierType = def.isFactory and "FACTORY" or (def.isBuilder and "BUILDER" or "UNIT")
	local tierStr = "T" .. (item.techTier or 1) .. " " .. tierType

	-- Right Badges calculation
	local tierFontSize = 9.0 * uiScale
	local vsBadgeW = vsBadgeText and (getTextPixelWidth(vsBadgeText, 9.0 * uiScale) + 12 * uiScale) or 0
	local tierW = getTextPixelWidth(tierStr, tierFontSize)
	local rightUsedW = tierW + (vsBadgeText and (vsBadgeW + 8 * uiScale) or 0) + 12 * uiScale

	local maxTitleW = max(1, headerW - rightUsedW - 28 * uiScale)
	local title = fitTitleToWidth(rawName, maxTitleW, 11.0 * uiScale)
	gl.Scissor(floor(headerX + 18 * uiScale), floor(headerY), max(1, floor(maxTitleW)), max(1, floor(headerH)))
	drawText(title, headerX + 18 * uiScale, headerY + headerH * 0.5, 11.0 * uiScale, {0.98, 0.99, 1.0, 1.0}, "vo")
	gl.Scissor(false)

	-- Right-aligned badges (VS badge + Tech Tier Tag)
	local currentRightX = headerX + headerW - 10 * uiScale
	drawText(tierStr, currentRightX, headerY + headerH * 0.5, tierFontSize, {0.72, 0.88, 0.98, 0.90}, "vro")
	currentRightX = currentRightX - tierW - 8 * uiScale

	if vsBadgeText then
		-- Draw VS badge capsule
		local vsH = 16 * uiScale
		local vsY = headerY + (headerH - vsH) * 0.5
		local vsX = currentRightX - vsBadgeW + 4 * uiScale
		glColor(themeColor[1], themeColor[2], themeColor[3], 0.20)
		glRect(vsX, vsY, vsX + vsBadgeW, vsY + vsH)
		glColor(themeColor[1], themeColor[2], themeColor[3], 0.85)
		glRect(vsX, vsY, vsX + vsBadgeW, vsY + 1 * uiScale)
		glRect(vsX, vsY + vsH - 1 * uiScale, vsX + vsBadgeW, vsY + vsH)
		glRect(vsX, vsY, vsX + 1 * uiScale, vsY + vsH)
		glRect(vsX + vsBadgeW - 1 * uiScale, vsY, vsX + vsBadgeW, vsY + vsH)
		drawText(vsBadgeText, vsX + vsBadgeW * 0.5, vsY + vsH * 0.5, 9.0 * uiScale, themeColor, "voco")
	end

	local colW = boxW - padX * 2
	local colX = boxX + padX
	local startY = headerY - 10 * uiScale - (pillH + meterH + 2 * uiScale)
	for i = 1, #rows do
		local r = rows[i]
		local diffStr, diffColor = nil, nil
		if baseDataForDiff and r.numVal then
			local baseRow = baseDataForDiff.rowMap[r.key]
			if baseRow and baseRow.numVal then diffStr, diffColor = getNumericDiff(baseRow.numVal, r.numVal, r.lowerIsBetter, r.unitSuffix) end
		end
		drawStatPill(colX, startY - (i - 1) * stepY, colW, pillH, meterH, r.label, r.val, r.color, r.ticks, 20, diffStr, diffColor)
	end
end

local RADAR_AXES = {
	{ label = "SURVIVAL",  color = {0.30, 0.95, 0.55} }, -- 12 o'clock (Top)
	{ label = "FIREPOWER", color = {0.98, 0.28, 0.28} }, -- 2 o'clock (Top-Right)
	{ label = "RANGE",     color = {0.98, 0.78, 0.18} }, -- 4 o'clock (Bottom-Right)
	{ label = "MOBILITY",  color = {0.20, 0.68, 1.00} }, -- 6 o'clock (Bottom)
	{ label = "SENSORS",   color = {0.62, 0.94, 0.25} }, -- 8 o'clock (Bottom-Left)
	{ label = "ECONOMY",   color = {0.85, 0.95, 0.20} }, -- 10 o'clock (Top-Left)
}

local function getUnitRadarScores(intel, def, item)
	if not intel or not def then return {0.1, 0.1, 0.1, 0.1, 0.1, 0.1} end
	local primaryWeapon = (intel.weapons and intel.weapons[1])

	-- 1. Survivability (HP + Shield + AutoHeal)
	local hp = (intel.maxHP or 0) + (primaryWeapon and primaryWeapon.isShield and primaryWeapon.shieldPower or 0) * 1.2 + (intel.autoHeal or 0) * 40
	local s_hp = min(1.0, max(0.08, hp / 25000))

	-- 2. Firepower (DPS / Burst)
	local dps = max(intel.totalDPS or 0, (intel.buildSpeed or 0) * 4)
	if primaryWeapon and primaryWeapon.burst then dps = max(dps, primaryWeapon.burst * 0.8) end
	local s_dps = min(1.0, max(0.08, dps / 2200))

	-- 3. Range (Weapon Range / Build Distance)
	local range = max(def.maxWeaponRange or 0, (primaryWeapon and primaryWeapon.range or 0), (intel.buildDistance or 0) * 4)
	local s_rng = min(1.0, max(0.08, range / 1400))

	-- 4. Mobility (Speed / Turn)
	local spd = 0.08
	if intel.move.speed > 0 and not intel.move.isBuilding then
		spd = min(1.0, max(0.08, (intel.move.speed * 0.85 + (intel.move.turn or 0) * 0.2) / 100))
	end

	-- 5. Sensors (Sight / Radar / Sonar / Jammer)
	local recon = max(intel.los.los or 0, (intel.los.airLos or 0) * 0.8, (intel.radarRadius or 0) * 0.35, (intel.sonarRadius or 0) * 0.45)
	local s_recon = min(1.0, max(0.08, recon / 800))

	-- 6. Economy / Production (Metal Gen, Energy Gen, Storage, or Cost Efficiency)
	local ecoVal = (intel.energyMake or 0) * 2.5 + (intel.metalMake or 0) * 120 + (intel.energyStorage or 0) * 0.04
	local costVal = (intel.cost.metal or 0) * 0.8 + (intel.cost.energy or 0) * 0.02
	local eco = max(0.08, min(1.0, (ecoVal > 0 and (ecoVal / 3000) or (1.0 - min(0.9, costVal / 12000)))))
	local s_eco = eco

	return { s_hp, s_dps, s_rng, spd, s_recon, s_eco }
end

local function drawRadarChart(cx, cy, radius, scoresA, colorA, scoresB, colorB)
	local numAxes = 6
	local angleStep = (2 * pi) / numAxes
	local startAngle = -pi * 0.5

	-- 1. Outer background hexagon fill: Translucent Dark
	glColor(0.015, 0.025, 0.038, 0.76)
	gl.BeginEnd((GL and GL.TRIANGLE_FAN or 6), function()
		gl.Vertex(cx, cy)
		for i = 1, numAxes + 1 do
			local ang = startAngle + (i - 1) * angleStep
			gl.Vertex(cx + cos(ang) * radius, cy + sin(ang) * radius)
		end
	end)

	-- 2. Concentric Hexagon Grid Web Rings (25%, 50%, 75%, 100%)
	local rings = {0.25, 0.50, 0.75, 1.00}
	for r = 1, #rings do
		local lvl = rings[r]
		local rRad = radius * lvl
		if lvl == 1.00 then
			glColor(0.55, 0.78, 0.95, 0.55)
			gl.LineWidth(1.5 * uiScale)
		else
			glColor(0.40, 0.65, 0.85, 0.30)
			gl.LineWidth(1.0 * uiScale)
		end
		gl.BeginEnd((GL and GL.LINE_LOOP or 2), function()
			for i = 1, numAxes do
				local ang = startAngle + (i - 1) * angleStep
				gl.Vertex(cx + cos(ang) * rRad, cy + sin(ang) * rRad)
			end
		end)
	end

	-- 3. Radial Axis Spokes (from center to outer ring)
	glColor(0.45, 0.70, 0.90, 0.35)
	gl.LineWidth(1.0 * uiScale)
	gl.BeginEnd((GL and GL.LINES or 1), function()
		for i = 1, numAxes do
			local ang = startAngle + (i - 1) * angleStep
			gl.Vertex(cx, cy)
			gl.Vertex(cx + cos(ang) * radius, cy + sin(ang) * radius)
		end
	end)

	-- 4. Unit A Polygon (Single or Base Unit in Gold/Cyan)
	if scoresA then
		local cA = colorA or {0.38, 0.88, 1.00}
		-- Translucent Fill
		glColor(cA[1], cA[2], cA[3], 0.28)
		gl.BeginEnd((GL and GL.TRIANGLE_FAN or 6), function()
			gl.Vertex(cx, cy)
			for i = 1, numAxes + 1 do
				local idx = ((i - 1) % numAxes) + 1
				local ang = startAngle + (i - 1) * angleStep
				local sc = min(1.0, max(0.08, scoresA[idx] or 0.1))
				gl.Vertex(cx + cos(ang) * radius * sc, cy + sin(ang) * radius * sc)
			end
		end)
		-- Glowing Contour
		glColor(cA[1], cA[2], cA[3], 0.95)
		gl.LineWidth(2.0 * uiScale)
		gl.BeginEnd((GL and GL.LINE_LOOP or 2), function()
			for i = 1, numAxes do
				local ang = startAngle + (i - 1) * angleStep
				local sc = min(1.0, max(0.08, scoresA[i] or 0.1))
				gl.Vertex(cx + cos(ang) * radius * sc, cy + sin(ang) * radius * sc)
			end
		end)
		-- Glowing Vertex Points
		for i = 1, numAxes do
			local ang = startAngle + (i - 1) * angleStep
			local sc = min(1.0, max(0.08, scoresA[i] or 0.1))
			local vx = cx + cos(ang) * radius * sc
			local vy = cy + sin(ang) * radius * sc
			glColor(cA[1], cA[2], cA[3], 1.0)
			glRect(vx - 2 * uiScale, vy - 2 * uiScale, vx + 2 * uiScale, vy + 2 * uiScale)
			glColor(1, 1, 1, 0.8)
			glRect(vx - 1 * uiScale, vy - 1 * uiScale, vx + 1 * uiScale, vy + 1 * uiScale)
		end
	end

	-- 5. Unit B Polygon (if comparing 2 units)
	if scoresB then
		local cB = colorB or {0.30, 0.85, 1.00}
		-- Translucent Fill
		glColor(cB[1], cB[2], cB[3], 0.28)
		gl.BeginEnd((GL and GL.TRIANGLE_FAN or 6), function()
			gl.Vertex(cx, cy)
			for i = 1, numAxes + 1 do
				local idx = ((i - 1) % numAxes) + 1
				local ang = startAngle + (i - 1) * angleStep
				local sc = min(1.0, max(0.08, scoresB[idx] or 0.1))
				gl.Vertex(cx + cos(ang) * radius * sc, cy + sin(ang) * radius * sc)
			end
		end)
		-- Glowing Contour
		glColor(cB[1], cB[2], cB[3], 0.95)
		gl.LineWidth(2.0 * uiScale)
		gl.BeginEnd((GL and GL.LINE_LOOP or 2), function()
			for i = 1, numAxes do
				local ang = startAngle + (i - 1) * angleStep
				local sc = min(1.0, max(0.08, scoresB[i] or 0.1))
				gl.Vertex(cx + cos(ang) * radius * sc, cy + sin(ang) * radius * sc)
			end
		end)
		-- Glowing Vertex Points
		for i = 1, numAxes do
			local ang = startAngle + (i - 1) * angleStep
			local sc = min(1.0, max(0.08, scoresB[i] or 0.1))
			local vx = cx + cos(ang) * radius * sc
			local vy = cy + sin(ang) * radius * sc
			glColor(cB[1], cB[2], cB[3], 1.0)
			glRect(vx - 2 * uiScale, vy - 2 * uiScale, vx + 2 * uiScale, vy + 2 * uiScale)
			glColor(1, 1, 1, 0.8)
			glRect(vx - 1 * uiScale, vy - 1 * uiScale, vx + 1 * uiScale, vy + 1 * uiScale)
		end
	end

	gl.LineWidth(1.0)

	-- 6. Outer Axis Labels
	local labelOffset = radius + 10 * uiScale
	for i = 1, numAxes do
		local ang = startAngle + (i - 1) * angleStep
		local lx = cx + cos(ang) * labelOffset
		local ly = cy + sin(ang) * labelOffset
		local axis = RADAR_AXES[i]
		local align = "vc"
		if i == 1 then align = "oc"
		elseif i == 2 then align = "vo"
		elseif i == 3 then align = "vo"
		elseif i == 4 then align = "uc"
		elseif i == 5 then align = "vro"
		elseif i == 6 then align = "vro"
		end
		drawText(axis.label, lx, ly, 7.8 * uiScale, axis.color, align)
	end
end

local function drawRadarBoxContainer(boxX, boxY, boxW, boxH, itemA, itemB)
	local defA = UnitDefs[itemA.unitDefID]
	if not defA then return end
	local intelA = getDetailedUnitIntel(defA, itemA)
	local scoresA = getUnitRadarScores(intelA, defA, itemA)

	local scoresB = nil
	local defB = itemB and UnitDefs[itemB.unitDefID]
	if defB then
		local intelB = getDetailedUnitIntel(defB, itemB)
		scoresB = getUnitRadarScores(intelB, defB, itemB)
	end

	local activeCategoryColor = CATEGORIES[categoryIndex(activeCategory)].color or UI_COLORS.accent
	local themeColor = scoresB and {0.38, 0.88, 1.00} or activeCategoryColor

	-- 1. Outer Glass Panel Container: Translucent Dark
	drawGlassRect(boxX, boxY, boxX + boxW, boxY + boxH, {0.015, 0.025, 0.038, 0.76}, UI_COLORS.panelBorder, themeColor)

	-- 2. Top Header Bar: Unified Header Size & Metrics
	local headerH = 26 * uiScale
	local headerPad = 8 * uiScale
	local headerX = boxX + headerPad
	local headerW = boxW - headerPad * 2
	local headerY = boxY + boxH - 8 * uiScale - headerH

	glColor(0.020, 0.045, 0.070, 0.76)
	glRect(headerX, headerY, headerX + headerW, headerY + headerH)
	glColor(themeColor[1], themeColor[2], themeColor[3], 0.90)
	glRect(headerX, headerY + headerH - 1.5 * uiScale, headerX + headerW, headerY + headerH)
	glColor(0.35, 0.65, 0.85, 0.45)
	glRect(headerX, headerY, headerX + headerW, headerY + 1 * uiScale)
	glColor(0.35, 0.65, 0.85, 0.45)
	glRect(headerX, headerY, headerX + 1 * uiScale, headerY + headerH)
	glRect(headerX + headerW - 1 * uiScale, headerY, headerX + headerW, headerY + headerH)

	-- Left glowing indicator pip
	glColor(themeColor[1], themeColor[2], themeColor[3], 1.0)
	glRect(headerX + 8 * uiScale, headerY + 6 * uiScale, headerX + 11.5 * uiScale, headerY + headerH - 6 * uiScale)

	local titleText = "TACTICAL RADAR SPECTRUM"
	drawText(titleText, headerX + 18 * uiScale, headerY + headerH * 0.5, 10.5 * uiScale, {0.96, 0.98, 1.0, 1.0}, "vo")

	-- Right Legend in Header if comparing 2 units
	if scoresB then
		local legX = headerX + headerW - 10 * uiScale
		drawText("VS 2", legX, headerY + headerH * 0.5, 9.0 * uiScale, {0.30, 0.85, 1.00, 1.0}, "vro")
		local vs2W = getTextPixelWidth("VS 2", 9.0 * uiScale)
		drawText("vs", legX - vs2W - 6 * uiScale, headerY + headerH * 0.5, 8.5 * uiScale, {0.65, 0.75, 0.85, 0.80}, "vro")
		local vsW = getTextPixelWidth("vs", 8.5 * uiScale)
		drawText("VS 1", legX - vs2W - vsW - 12 * uiScale, headerY + headerH * 0.5, 9.0 * uiScale, {1.00, 0.85, 0.20, 1.0}, "vro")
	else
		drawText("RADAR MATRIX", headerX + headerW - 10 * uiScale, headerY + headerH * 0.5, 8.5 * uiScale, {0.55, 0.78, 0.95, 0.75}, "vro")
	end

	-- 3. Draw Spider Web Chart in Center
	local cx = boxX + boxW * 0.5
	local cy = boxY + (boxH - headerH) * 0.44 + 1 * uiScale
	local radius = min(boxW * 0.22, (boxH - headerH) * 0.31)

	local colorA = scoresB and {1.00, 0.85, 0.20} or activeCategoryColor
	local colorB = scoresB and {0.30, 0.85, 1.00} or nil

	drawRadarChart(cx, cy, radius, scoresA, colorA, scoresB, colorB)
end

local function drawUnitTooltipInfoBox(item, vsBadge)
	if not item or not item.unitDefID then return end
	local def = UnitDefs[item.unitDefID]
	if not def then return end
	local intel = getDetailedUnitIntel(def, item)
	if not intel then return end
	local data = buildUnitIntelRows(intel, def, item)
	if not data then return end

	local boxW = 408 * uiScale
	local padX = 12 * uiScale
	local headerH = 26 * uiScale
	local pillH = 17 * uiScale
	local meterH = 5 * uiScale
	local stepY = (pillH + meterH + 8) * uiScale

	local radarH = 165 * uiScale
	local numRows = #data.rows
	local maxTotalAvailableH = vsy - 20 * uiScale
	local neededH = headerH + numRows * stepY + 16 * uiScale
	local boxH = neededH

	if neededH + radarH + 6 * uiScale > maxTotalAvailableH then
		boxH = maxTotalAvailableH - radarH - 6 * uiScale
		stepY = (boxH - headerH - 18 * uiScale) / numRows
		pillH = min(17 * uiScale, max(11 * uiScale, stepY * 0.58))
		meterH = min(5 * uiScale, max(2.5 * uiScale, stepY * 0.20))
	end

	local boxY = menuY or (10 * uiScale)
	if boxY + boxH + radarH + 6 * uiScale > vsy - 6 * uiScale then
		boxY = vsy - boxH - radarH - 10 * uiScale
	end
	if boxY < 8 * uiScale then boxY = 8 * uiScale end

	local boxX = (menuX or 100) + (menuW or 400) + 6 * uiScale
	if boxX + boxW > vsx - 8 * uiScale then boxX = (menuX or 100) - boxW - 6 * uiScale end
	if boxX < 8 * uiScale then boxX = 8 * uiScale end

	local radarY = boxY + boxH + 6 * uiScale

	-- Draw Radar Chart Module directly above the Info Box
	drawRadarBoxContainer(boxX, radarY, boxW, radarH, item, nil)

	-- Draw Detailed Stat Box below Radar Chart
	drawSingleUnitBox(boxX, boxY, boxW, boxH, headerH, pillH, meterH, stepY, padX, data, vsBadge, nil, nil)
end

local function drawUnitComparisonInfoBox(itemA, itemB)
	if not itemA or not itemB or not itemA.unitDefID or not itemB.unitDefID then return end
	local defA = UnitDefs[itemA.unitDefID]
	local defB = UnitDefs[itemB.unitDefID]
	if not defA or not defB then return end
	local intelA = getDetailedUnitIntel(defA, itemA)
	local intelB = getDetailedUnitIntel(defB, itemB)
	if not intelA or not intelB then return end
	local dataA = buildUnitIntelRows(intelA, defA, itemA)
	local dataB = buildUnitIntelRows(intelB, defB, itemB)
	if not dataA or not dataB then return end

	local boxW = 408 * uiScale
	local gapX = 8 * uiScale
	local totalW = boxW * 2 + gapX
	local padX = 12 * uiScale
	local headerH = 26 * uiScale
	local pillH = 17 * uiScale
	local meterH = 5 * uiScale
	local stepY = (pillH + meterH + 8) * uiScale

	local radarH = 165 * uiScale
	local maxRows = max(#dataA.rows, #dataB.rows)
	local maxTotalAvailableH = vsy - 20 * uiScale
	local neededH = headerH + maxRows * stepY + 16 * uiScale
	local boxH = neededH

	if neededH + radarH + 6 * uiScale > maxTotalAvailableH then
		boxH = maxTotalAvailableH - radarH - 6 * uiScale
		stepY = (boxH - headerH - 18 * uiScale) / maxRows
		pillH = min(17 * uiScale, max(11 * uiScale, stepY * 0.58))
		meterH = min(5 * uiScale, max(2.5 * uiScale, stepY * 0.20))
	end

	local boxY = menuY or (10 * uiScale)
	if boxY + boxH + radarH + 6 * uiScale > vsy - 6 * uiScale then
		boxY = vsy - boxH - radarH - 10 * uiScale
	end
	if boxY < 8 * uiScale then boxY = 8 * uiScale end

	local boxX = (menuX or 100) + (menuW or 400) + 6 * uiScale
	if boxX + totalW > vsx - 8 * uiScale then boxX = max(8 * uiScale, vsx - totalW - 8 * uiScale) end

	local radarY = boxY + boxH + 6 * uiScale

	-- Draw Dual Overlay Spider Web Chart directly above the comparison boxes
	drawRadarBoxContainer(boxX, radarY, totalW, radarH, itemA, itemB)

	-- Draw Side-by-Side Dual Stat Boxes
	drawSingleUnitBox(boxX, boxY, boxW, boxH, headerH, pillH, meterH, stepY, padX, dataA, "VS 1", {1.00, 0.85, 0.20, 1.0}, nil)
	drawSingleUnitBox(boxX + boxW + gapX, boxY, boxW, boxH, headerH, pillH, meterH, stepY, padX, dataB, "VS 2", {0.30, 0.85, 1.00, 1.0}, dataA)
end

function widget:DrawScreen()
	local mx, my = spGetMouseState and spGetMouseState()
	if mx and my then
		screenMouseX = mx
		screenMouseY = my
	end
	hoveredItem = nil
	drawMenu()
	if pinnedCompareItem and pinnedCompareItemB then
		pcall(drawUnitComparisonInfoBox, pinnedCompareItem, pinnedCompareItemB)
	elseif pinnedCompareItem and hoveredItem and hoveredItem.unitDefID ~= pinnedCompareItem.unitDefID then
		pcall(drawUnitComparisonInfoBox, pinnedCompareItem, hoveredItem)
	elseif hoveredItem then
		pcall(drawUnitTooltipInfoBox, hoveredItem)
	end
	if WG then
		WG.hoveredUnitDefID = hoveredItem and hoveredItem.unitDefID or (pinnedCompareItem and pinnedCompareItem.unitDefID or nil)
	end
end



function widget:MousePress(x, y, button)
	if (button ~= 1 and button ~= 2 and button ~= 3) or not visible then return false end

	local inMenu = isInRect(x, y, menuX, menuY, menuX + menuW, menuY + menuH)
	if not inMenu then
		if button == 3 then
			pinnedCompareItem = nil
			pinnedCompareItemB = nil
		end
		return false
	end

	if button == 1 and dragHandle and isInRect(x, y, dragHandle.x1, dragHandle.y1, dragHandle.x2, dragHandle.y2) then
		return beginPanelDrag(x, y)
	end
	for i = 1, #tierTabs do
		local tab = tierTabs[i]
		if x >= tab.x1 and x <= tab.x2 and y >= tab.y1 and y <= tab.y2 then
			if button ~= 1 then return true end
			if activeTier ~= tab.tier then
				activeTier = tab.tier
				cardScroll = 0
				dirty = true
			end
			return true
		end
	end
	for i = 1, #tabs do
		local tab = tabs[i]
		if x >= tab.x1 and x <= tab.x2 and y >= tab.y1 and y <= tab.y2 then
			if button ~= 1 then return true end
			activeCategory = tab.key
			cardScroll = 0
			dirty = true
			return true
		end
	end
	for i = 1, #cardAreas do
		local area = cardAreas[i]
		if x >= area.x1 and x <= area.x2 and y >= area.y1 and y <= area.y2 then
			if button == 2 then
				if not pinnedCompareItem then
					pinnedCompareItem = area.item
					pinnedCompareItemB = nil
				elseif pinnedCompareItem.unitDefID == area.item.unitDefID then
					pinnedCompareItem = pinnedCompareItemB
					pinnedCompareItemB = nil
				elseif not pinnedCompareItemB then
					pinnedCompareItemB = area.item
				elseif pinnedCompareItemB.unitDefID == area.item.unitDefID then
					pinnedCompareItemB = nil
				else
					pinnedCompareItemB = area.item
				end
				return true
			end
			if factoryMode then
				local batchSize = 1
				if spGetModKeyState then
					local alt, ctrl, meta, shift = spGetModKeyState()
					if shift and ctrl then batchSize = 100 elseif ctrl then batchSize = 20 elseif shift then batchSize = 5 end
				end
				if area.minus and isInRect(x, y, area.minus.x1, area.minus.y1, area.minus.x2, area.minus.y2) then
					if (button == 1 or button == 3) and (area.item.queueCount or 0) > 0 then cancelFactoryQueue(area.item.unitDefID, batchSize) end
					return true
				end
				if area.plus and isInRect(x, y, area.plus.x1, area.plus.y1, area.plus.x2, area.plus.y2) then
					if button == 1 and not area.item.disabled then queueFactory(area.item.unitDefID, batchSize) elseif button == 3 and (area.item.queueCount or 0) > 0 then cancelFactoryQueue(area.item.unitDefID, batchSize) end
					return true
				end
				if button == 3 then
					if (area.item.queueCount or 0) > 0 then
						cancelFactoryQueue(area.item.unitDefID, batchSize)
					else
						pinnedCompareItem = nil
						pinnedCompareItemB = nil
					end
				elseif button == 1 and not area.item.disabled then
					queueFactory(area.item.unitDefID, batchSize)
				end
			elseif area.item.disabled then
				return true
			elseif button == 1 then
				pinnedCompareItem = nil
				pinnedCompareItemB = nil
				activateBuildCommand(area.item.unitDefID)
			elseif button == 3 then
				pinnedCompareItem = nil
				pinnedCompareItemB = nil
				if isPregameState() and WG and WG["pregame-build"] and WG["pregame-build"].setPreGamestartDefID then
					WG["pregame-build"].setPreGamestartDefID(nil)
				end
			end
			return true
		end
	end
	if button == 3 then
		pinnedCompareItem = nil
		pinnedCompareItemB = nil
		return true
	end
	if button == 1 and inMenu then
		return beginPanelDrag(x, y)
	end
	return false
end

function widget:MouseMove(x, y, dx, dy)
	if not panelDragging then return false end
	dx = dx or 0
	dy = dy or 0
	panelOffsetX = panelOffsetX + dx / max(uiScale, 0.01)
	panelOffsetY = panelOffsetY + dy / max(uiScale, 0.01)
	clampPanelPosition()
	return true
end

function widget:MouseRelease(_, _, button)
	if not panelDragging then return false end
	if button == 1 then
		panelDragging = false
		clampPanelPosition()
		return true
	end
	return false
end

function widget:MouseWheel(up, value)
	if not visible or maxCardScroll <= 0 then return false end
	local mx, my
	if spGetMouseState then mx, my = spGetMouseState() end
	if not mx or not my then return false end
	if mx < menuX or mx > menuX + menuW or my < menuY or my > menuY + menuH then
		return false
	end
	local step = max(1, floor(abs(value or 1)))
	if up then
		cardScroll = min(maxCardScroll, cardScroll + step)
	else
		cardScroll = max(0, cardScroll - step)
	end
	return true
end

function widget:KeyPress(key, _, isRepeat)
	if isRepeat or not visible then return false end
	local value = type(key) == "string" and lower(key) or ""
	if type(key) == "number" then
		if KEYSYMS then
			for i = 1, #CATEGORIES do
				local hotkey = lower(CATEGORIES[i].hotkey)
				local keySym = KEYSYMS[hotkey] or KEYSYMS[upper(hotkey)]
				if keySym and key == keySym then
					value = hotkey
					break
				end
			end
		end
		-- Some engine builds pass the SDL/ASCII code without exposing KEYSYMS
		-- to widgets.  Keep the visible Z/X/C/V shortcuts functional there too.
		if value == "" and key >= 65 and key <= 90 then
			value = lower(string.char(key))
		elseif value == "" and key >= 97 and key <= 122 then
			value = string.char(key)
		end
	end
	local category
	for i = 1, #CATEGORIES do
		if value == lower(CATEGORIES[i].hotkey) then
			category = CATEGORIES[i].key
			break
		end
	end
	-- Keep the familiar Economy shortcut as a compatibility fallback.
	if value == "z" then category = "economy" end
	if category and not factoryMode then
		activeCategory = category
		cardScroll = 0
		dirty = true
		return true
	end
	return false
end
