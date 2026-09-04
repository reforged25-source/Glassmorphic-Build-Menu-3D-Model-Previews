local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "HP Bars 2.0",
		desc = "Unified numeric unit readout with HP, status values, real-time movement speed, resource flows, build ETA, and floating RPG damage numbers. (v2.0 by reforged25-source)",
		author = "reforged25-source / Codex",
		version = "2.0",
		date = "2026 (v2.0)",
		license = "GNU GPL, v2 or later",
		handler = true,
		layer = -7,
		enabled = true,
	}
end

local abs = math.abs
local floor = math.floor
local ceil = math.ceil
local sqrt = math.sqrt
local max = math.max
local min = math.min

local spGetAllUnits = Spring.GetAllUnits
local spGetUnitAllyTeam = Spring.GetUnitAllyTeam
local spGetUnitLosState = Spring.GetUnitLosState
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitHealth = Spring.GetUnitHealth
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitShieldState = Spring.GetUnitShieldState
local spGetUnitStockpile = Spring.GetUnitStockpile
local spGetUnitIsStunned = Spring.GetUnitIsStunned
local spGetUnitWeaponState = Spring.GetUnitWeaponState
local spGetUnitResources = Spring.GetUnitResources
local spGetUnitVelocity = Spring.GetUnitVelocity
local spGetUnitViewPosition = Spring.GetUnitViewPosition
local spGetGameFrame = Spring.GetGameFrame
local spGetSpectatingState = Spring.GetSpectatingState
local spGetMyAllyTeamID = Spring.GetMyAllyTeamID
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamUnits = Spring.GetTeamUnits
local spGetGameSeconds = Spring.GetGameSeconds
local spIsGUIHidden = Spring.IsGUIHidden
local spGetAllFeatures = Spring.GetAllFeatures
local spGetFeatureDefID = Spring.GetFeatureDefID
local spGetFeaturePosition = Spring.GetFeaturePosition
local spGetFeatureHealth = Spring.GetFeatureHealth
local spGetFeatureResources = Spring.GetFeatureResources
local spIsPosInLos = Spring.IsPosInLos
local spGetUnitTeam = Spring.GetUnitTeam
local spGetTeamInfo = Spring.GetTeamInfo
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetTeamColor = Spring.GetTeamColor
local spGetAIInfo = Spring.GetAIInfo
local spGetUnitIsActive = Spring.GetUnitIsActive
local spGetUnitStates = Spring.GetUnitStates
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spIsUnitSelected = Spring.IsUnitSelected
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding

local SLEEP_DELAY_SECONDS = 8.0
local SLEEP_GROUP_RADIUS = 150.0
local unitLastActiveTime = {}
local unitLastHealth = {}

local function isUnitAwake(unitID, defID, health, maxHealth, currentSpeed, resourceFlow, paralyzeDamage, capture, buildProgress, now)
	if not unitID then return false end
	now = now or spGetGameSeconds()

	-- 1. Explicit Wait / Sleep state (the "Z" icon) -> ALWAYS SLEEPING (hide text immediately)
	if spGetUnitStates then
		local states = spGetUnitStates(unitID)
		if states then
			if states["wait"] == true or states.wait == true then
				unitLastActiveTime[unitID] = nil
				unitLastHealth[unitID] = health
				return false
			end
			-- If structure/unit has an On/Off toggle and is turned OFF -> SLEEPING (hide text immediately)
			if states.active == false then
				defID = defID or (spGetUnitDefID and spGetUnitDefID(unitID))
				local udef = defID and UnitDefs[defID]
				if udef and udef.onoffable then
					unitLastActiveTime[unitID] = nil
					unitLastHealth[unitID] = health
					return false
				end
			end
		end
	end

	-- 2. Explicit rules params for sleeping / waiting -> ALWAYS SLEEPING
	if spGetUnitRulesParam then
		local sleeping = spGetUnitRulesParam(unitID, "sleeping")
		if sleeping and (sleeping == 1 or sleeping == true) then
			unitLastActiveTime[unitID] = nil
			unitLastHealth[unitID] = health
			return false
		end
		local waiting = spGetUnitRulesParam(unitID, "waiting")
		if waiting and (waiting == 1 or waiting == true) then
			unitLastActiveTime[unitID] = nil
			unitLastHealth[unitID] = health
			return false
		end
		local waitParam = spGetUnitRulesParam(unitID, "wait")
		if waitParam and (waitParam == 1 or waitParam == true) then
			unitLastActiveTime[unitID] = nil
			unitLastHealth[unitID] = health
			return false
		end
	end

	-- 3. Check if currently active / moving / HP changing right now
	local isCurrentlyActive = false

	-- Check if HP increased (healed/repaired) or decreased (damaged/hit)
	local prevHP = unitLastHealth[unitID]
	if prevHP ~= nil and health ~= nil and abs(health - prevHP) > 0.5 then
		isCurrentlyActive = true
	end
	unitLastHealth[unitID] = health

	-- If selected by player
	if spIsUnitSelected and spIsUnitSelected(unitID) then
		isCurrentlyActive = true
	-- If moving / walking (speed > 0.05 elmos/sec)
	elseif currentSpeed and currentSpeed > 0.05 then
		isCurrentlyActive = true
	-- If EMP paralyzed, stunned, or being captured
	elseif (paralyzeDamage and paralyzeDamage > 0) or (capture and capture > 0) then
		isCurrentlyActive = true
	-- If under construction / building progress < 99.5%
	elseif buildProgress and buildProgress < 0.995 then
		isCurrentlyActive = true
	-- If actively constructing / repairing / reclaiming
	elseif spGetUnitIsBuilding and spGetUnitIsBuilding(unitID) then
		isCurrentlyActive = true
	else
		-- For stationary structures: check active resource flow (e.g. Solar / Fusion / Wind / Metal Maker)
		defID = defID or (spGetUnitDefID and spGetUnitDefID(unitID))
		local udef = defID and UnitDefs[defID]
		if udef and udef.isBuilding then
			if resourceFlow and (resourceFlow.metalMade > 0.05 or resourceFlow.metalUsed > 0.05 or resourceFlow.energyMade > 0.05 or resourceFlow.energyUsed > 0.05) then
				isCurrentlyActive = true
			end
		end
	end

	if isCurrentlyActive then
		-- Update timestamp of last active / HP changing moment
		unitLastActiveTime[unitID] = now
		return true
	end

	-- If not currently active and HP is stable/not changing, check if within the 8-second grace period
	local lastActive = unitLastActiveTime[unitID]
	if lastActive and (now - lastActive < SLEEP_DELAY_SECONDS) then
		-- Still awake during the 8-second cooldown!
		return true
	end

	-- After 8 seconds of HP being still and no movement/activity, unit goes to sleep / hides text
	return false
end

local glColor = gl.Color
local glDepthTest = gl.DepthTest
local glDrawFuncAtUnit = gl.DrawFuncAtUnit
local glBillboard = gl.Billboard
local glTranslate = gl.Translate
local glScale = gl.Scale
local glPushMatrix = gl.PushMatrix
local glPopMatrix = gl.PopMatrix
local glRect = gl.Rect
local glGetTextWidth = gl.GetTextWidth

local myAllyTeam
local fullview
local font
local trackedUnits = {}
local trackedFeatures = {}
local activeDamagedFeatures = {}
local unitHeight = {}
local unitMeta = {}
local featureHeight = {}
local teamCache = {}
local lastStateCheck = -1

local function getTeamNameAndColor(teamID)
	if not teamID then return nil, nil end
	local _, leaderPlayerID, isDead, isAiTeam = spGetTeamInfo(teamID, false)
	local name
	if isAiTeam then
		local _, aiName = spGetAIInfo and spGetAIInfo(teamID)
		name = aiName or ("AI " .. teamID)
	elseif leaderPlayerID and leaderPlayerID >= 0 then
		name = spGetPlayerInfo(leaderPlayerID)
	end
	if not name or name == "" then
		name = "Team " .. teamID
	end

	local r, g, b, a = 0.95, 0.95, 0.95, 1
	if spGetTeamColor then
		local tr, tg, tb, ta = spGetTeamColor(teamID)
		if tr and tg and tb then
			local maxC = max(tr, max(tg, tb))
			if maxC < 0.45 and maxC > 0.01 then
				local boost = 0.45 / maxC
				tr, tg, tb = min(1, tr * boost), min(1, tg * boost), min(1, tb * boost)
			elseif maxC <= 0.01 then
				tr, tg, tb = 0.85, 0.85, 0.85
			end
			r, g, b, a = tr, tg, tb, ta or 1
		end
	end
	return name, {r, g, b, a}
end

local function getCachedTeam(teamID)
	if not teamID then return nil, nil end
	local cached = teamCache[teamID]
	if cached then
		return cached.name, cached.color
	end
	local name, color = getTeamNameAndColor(teamID)
	teamCache[teamID] = {name = name, color = color}
	return name, color
end
-- When a group of units is packed together, repeating the same HP line over
-- every unit makes the readout unreadable.  Keep one deterministic HP label
-- for nearby units with the same *actual* health values.  The same rule is
-- applied independently to SPEED and M/E flow; other lines (shield, status,
-- etc.) are left untouched because they can differ per unit.
local healthLabelSuppressed = {}
local speedLabelSuppressed = {}
local resourceLabelSuppressed = {}

local HP_DEDUP_DISTANCE = 96
local HP_DEDUP_DISTANCE_SQ = HP_DEDUP_DISTANCE * HP_DEDUP_DISTANCE
local SPEED_DEDUP_DISTANCE = 160
local SPEED_DEDUP_DISTANCE_SQ = SPEED_DEDUP_DISTANCE * SPEED_DEDUP_DISTANCE
-- Only absorb floating-point noise; a real health difference is kept visible.
local HP_EQUAL_EPSILON = 0.0001
local RESOURCE_EQUAL_EPSILON = 0.0001

-- Keep the stock bars out of the way while this widget supplies the numeric
-- readout.  The second name is supported for older BAR builds that used the
-- pre-GL4 widget name.
local STOCK_OVERLAY_WIDGET_NAMES = {
	"Health Bars GL4",
	"Health Bars",
}

local function hideStockBars()
	if widgetHandler and widgetHandler.DisableWidget then
		for _, widgetName in ipairs(STOCK_OVERLAY_WIDGET_NAMES) do
			local known = widgetHandler.knownWidgets and widgetHandler.knownWidgets[widgetName]
			if known and known.active then
				widgetHandler:DisableWidget(widgetName)
			end
		end
	end
end

local UPDATE_SECONDS = 0.25
-- Squared world-space cutoff for a 1,600-elmo display radius.
local MAX_DRAW_DISTANCE = 2.56e6
local SCREEN_REF_DISTANCE = 800.0
local LABEL_SIZE = 7.5      -- reduced 10% (from 8.3)
local ROW_STEP = 8.7        -- reduced 10% (from 9.7)
-- GetUnitVelocity is reported in elmos/frame; resource/UnitDef speed values
-- are conventionally read as elmos/second in the HUD.
local GAME_SPEED = (Game and Game.gameSpeed) or 30
-- Offset used above unit height to place the text closely above the model.
local SYSTEM_BAR_OFFSET = 6
-- Additional vertical raise offset.
local LABEL_RAISE = 0

-- Floating RPG damage number constants
local DAMAGE_LIFETIME = 1.15
local RISE_SPEED = 18
local MAX_DAMAGE_NUMBERS = 120
local DAMAGE_TEXT_SIZE = 8.7  -- reduced 10% (from 9.7)
local damageNumbers = {}
local shieldSnapshots = {}

local function cacheUnitDefs()
	unitHeight = {}
	unitMeta = {}
	for defID, unitDef in pairs(UnitDefs) do
		unitHeight[defID] = unitDef.height or 20
		local meta = {
			height = unitHeight[defID],
			speed = unitDef.speed or 0,
			metalCost = unitDef.metalCost or 0,
			energyCost = unitDef.energyCost or 0,
			canStockpile = unitDef.canStockpile == true,
			shieldMax = nil,
			primaryWeapon = nil,
			reloadTime = 0,
		}
		local shieldDefID = unitDef.shieldWeaponDef
		local shieldDef = shieldDefID and WeaponDefs[shieldDefID]
		if shieldDef and shieldDef.shieldPower then
			meta.shieldMax = shieldDef.shieldPower
		end
		local reloadTime = unitDef.reloadTime or 0
		for weaponIndex, weapon in ipairs(unitDef.weapons or {}) do
			local weaponDef = WeaponDefs[weapon.weaponDef]
			if weaponDef and weaponDef.reload and weaponDef.reload > reloadTime then
				reloadTime = weaponDef.reload
				meta.primaryWeapon = weaponIndex
			end
		end
		if meta.primaryWeapon and reloadTime > 4 then
			meta.reloadTime = reloadTime
		else
			meta.primaryWeapon = nil
		end

		local isHero = false
		if unitDef.customParams and (unitDef.customParams.iscommander or unitDef.customParams.commander or unitDef.customParams.hero) then
			isHero = true
		elseif unitDef.name then
			local n = unitDef.name:lower()
			if n:find("armcom") or n:find("corcom") or n:find("legcom") or n:find("commander") or n:find("herocom") then
				isHero = true
			end
		end
		meta.isHero = isHero

		unitMeta[defID] = meta
	end
	featureHeight = {}
	for defID, featureDef in pairs(FeatureDefs or {}) do
		featureHeight[defID] = featureDef.height or 32
	end
end

local function canSeeUnit(unitID)
	if fullview or spGetUnitAllyTeam(unitID) == myAllyTeam then return true end
	local losState = spGetUnitLosState and spGetUnitLosState(unitID, myAllyTeam)
	return losState and losState.los == true
end

local function addUnit(unitID, unitDefID)
	if not unitDefID then unitDefID = spGetUnitDefID(unitID) end
	if unitDefID and canSeeUnit(unitID) then
		trackedUnits[unitID] = {defID = unitDefID, meta = unitMeta[unitDefID], height = unitHeight[unitDefID] or 20, eta = {}}
		unitLastActiveTime[unitID] = unitLastActiveTime[unitID] or spGetGameSeconds()
		local hp = spGetUnitHealth(unitID)
		if hp then unitLastHealth[unitID] = hp end
	end
end

local function addFeature(featureID)
	local defID = spGetFeatureDefID(featureID)
	if defID then
		trackedFeatures[featureID] = {defID = defID, height = featureHeight[defID] or 32, eta = {}}
	end
end

local function rebuildUnitList()
	trackedUnits = {}
	for _, unitID in ipairs(spGetAllUnits() or {}) do
		addUnit(unitID, spGetUnitDefID(unitID))
	end
	trackedFeatures = {}
	for _, featureID in ipairs(spGetAllFeatures and spGetAllFeatures() or {}) do
		addFeature(featureID)
	end
end

local function clampPercent(value)
	return max(0, min(1, value or 0))
end

local function healthTextColor(progress)
	progress = clampPercent(progress)
	if progress >= 0.5 then
		local t = (progress - 0.5) * 2
		return {1 - 0.70 * t, 1.00, 0.10}
	end
	return {1.00, 0.15 + progress * 1.70, 0.08}
end

local function drawText(value, x, y, size, color, options)
	color = color or {0.96, 0.96, 0.96, 1}
	options = options or "voco"
	if font then
		font:Begin()
		font:SetTextColor(color[1], color[2], color[3], color[4] or 1)
		font:Print(value, x, y, size, options)
		font:End()
	else
		glColor(color[1], color[2], color[3], color[4] or 1)
		gl.Text(value, x, y, size, options)
	end
end

local TEXT_COLORS = {
	eta = {0.25, 1.00, 0.30, 1},
	decaying = {1.00, 0.15, 0.10, 1},
	cost = {0.95, 0.95, 0.75, 1},
	shield = {0.25, 0.85, 1.00, 1},
	capture = {1.00, 0.50, 0.10, 1},
	stockpile = {1.00, 0.88, 0.25, 1},
	emp = {0.55, 0.60, 1.00, 1},
	reload = {0.15, 0.85, 0.85, 1},
	building = {1.00, 0.78, 0.05, 1},
	resource = {0.55, 0.90, 1.00, 1},
	speed = {0.35, 0.95, 0.75, 1},
	paralyzed = {0.75, 0.45, 1.00, 1},
	featureHealth = {0.80, 0.80, 0.80, 1},
	reclaim = {0.30, 1.00, 0.45, 1},
	resurrect = {1.00, 0.35, 1.00, 1},
	player = {0.95, 0.95, 0.95, 1},
}

local function addLabel(labels, value, color)
	labels[#labels + 1] = {value, color}
end

local function drawLabels(labels, yoffset, cameraDist, offsetX, offsetY)
	glTranslate(0, yoffset, 10)
	glBillboard()
	if cameraDist and cameraDist > 0 then
		local s = cameraDist / SCREEN_REF_DISTANCE
		glScale(s, s, s)
	end
	if offsetX and (offsetX ~= 0 or (offsetY and offsetY ~= 0)) then
		glTranslate(offsetX, offsetY or 0, 0)
	end
	for i = 1, #labels do
		local label = labels[i]
		local txt = label[1]
		-- Stack upwards from the unit's top offset with clean text outline
		local lineY = (i - 1) * ROW_STEP
		drawText(txt, 0, lineY, LABEL_SIZE, label[2], "voco")
	end
end

local function formatSeconds(seconds)
	if not seconds then return "?" end
	if seconds >= 60 then
		return string.format("%d:%02d", floor(seconds / 60), floor(seconds % 60))
	end
	return string.format("%.1fs", max(0, seconds))
end

local function formatThousands(n)
	if n == nil then return "0" end
	local num = floor(n + 0.5)
	local str = tostring(abs(num))
	local formatted = str:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	if num < 0 then
		return "-" .. formatted
	end
	return formatted
end

local function formatCount(n)
	if n == nil then return "0" end
	local sign = n < 0 and "-" or ""
	local absn = abs(n)
	local function trim(value)
		return value:gsub("%.?0+$", "")
	end
	if absn >= 1e6 then
		return sign .. trim(string.format("%.1f", absn / 1e6)) .. "M"
	elseif absn >= 1e4 then
		return sign .. trim(string.format("%.1f", absn / 1e3)) .. "K"
	end
	return sign .. formatThousands(absn)
end

-- Unit resource rates are per-second flows.  Preserve a decimal for small
-- rates and keep production (+) separate from consumption (-) when a unit
-- does both at once.
local function formatRateMagnitude(value)
	local magnitude = abs(value or 0)
	if magnitude < 0.05 then return "0" end
	local function trim(valueString)
		return valueString:gsub("%.?0+$", "")
	end
	if magnitude >= 1e6 then
		return trim(string.format("%.1f", magnitude / 1e6)) .. "M"
	elseif magnitude >= 1e4 then
		return trim(string.format("%.1f", magnitude / 1e3)) .. "K"
	elseif magnitude >= 1e3 then
		return formatThousands(magnitude)
	end
	return trim(string.format("%.1f", magnitude))
end

local function formatResourceFlow(made, used)
	local parts = {}
	if made and made > 0.05 then parts[#parts + 1] = "+" .. formatRateMagnitude(made) end
	if used and used > 0.05 then parts[#parts + 1] = "-" .. formatRateMagnitude(used) end
	return #parts > 0 and table.concat(parts, "/") or "0"
end

local function formatETA(seconds)
	seconds = max(0, seconds or 0)
	return string.format("%02d:%02d", floor(seconds / 60), floor(seconds % 60))
end

local function formatDamage(value)
	value = max(0, value or 0)
	if value >= 1000000 then
		return string.format("%.1fM", value / 1000000):gsub("%.0M$", "M")
	elseif value >= 10000 then
		return string.format("%.1fK", value / 1000):gsub("%.0K$", "K")
	end
	return formatThousands(value)
end

local function pushDamageNumber(unitID, unitTeam, damage, paralyzer)
	if not damage or damage <= 0 then return end
	local myTeam = spGetMyTeamID and spGetMyTeamID()
	local allyTeam = spGetUnitAllyTeam and spGetUnitAllyTeam(unitID)
	if not (fullview or (unitTeam and unitTeam == myTeam) or (allyTeam and allyTeam == myAllyTeam)) then return end
	local x, y, z = spGetUnitViewPosition(unitID, true)
	if not x then return end

	local _, maxHealth = spGetUnitHealth(unitID)
	local critical = maxHealth and maxHealth > 0 and damage >= maxHealth * 0.15
	local label
	local color
	if paralyzer then
		label = "EMP " .. formatDamage(damage)
		color = {0.72, 0.45, 1.00, 1}
	elseif critical then
		label = "CRIT -" .. formatDamage(damage)
		color = {1.00, 0.72, 0.10, 1}
	else
		label = "-" .. formatDamage(damage)
		color = {1.00, 0.20, 0.16, 1}
	end

	damageNumbers[#damageNumbers + 1] = {
		unitID = unitID,
		spawnTime = spGetGameSeconds(),
		label = label,
		color = color,
		critical = critical,
		x = x,
		y = y,
		z = z,
	}
	while #damageNumbers > MAX_DAMAGE_NUMBERS do
		table.remove(damageNumbers, 1)
	end
end

local function pushShieldNumber(unitID, absorbed)
	if not absorbed or absorbed <= 0 then return end
	local x, y, z = spGetUnitViewPosition(unitID, true)
	if not x then return end
	damageNumbers[#damageNumbers + 1] = {
		unitID = unitID,
		spawnTime = spGetGameSeconds(),
		label = "SHIELD -" .. formatDamage(absorbed),
		color = {0.30, 0.82, 1.00, 1},
		critical = false,
		x = x,
		y = y,
		z = z,
	}
	while #damageNumbers > MAX_DAMAGE_NUMBERS do
		table.remove(damageNumbers, 1)
	end
end

local function updateShieldSnapshots()
	local myTeam = spGetMyTeamID and spGetMyTeamID()
	if not spGetUnitShieldState or not spGetTeamUnits or not myTeam then return end
	for _, unitID in ipairs(spGetTeamUnits(myTeam) or {}) do
		local shieldOn, shieldPower = spGetUnitShieldState(unitID)
		if shieldPower then
			local previousPower = shieldSnapshots[unitID]
			if previousPower and shieldOn ~= false and shieldPower < previousPower - 2 then
				pushShieldNumber(unitID, previousPower - shieldPower)
			end
			shieldSnapshots[unitID] = shieldPower
		elseif shieldOn == nil then
			shieldSnapshots[unitID] = nil
		end
	end
end

local function drawDamageNumbers(cameraX, cameraY, cameraZ)
	if #damageNumbers == 0 then return end
	local now = spGetGameSeconds()
	for i = #damageNumbers, 1, -1 do
		local entry = damageNumbers[i]
		local age = now - entry.spawnTime
		if age >= DAMAGE_LIFETIME then
			table.remove(damageNumbers, i)
		else
			local x, y, z = spGetUnitViewPosition(entry.unitID, true)
			if not x then
				x, y, z = entry.x, entry.y, entry.z
			end
			if x then
				local dx, dy, dz = x - cameraX, y - cameraY, z - cameraZ
				local distSq = dx * dx + dy * dy + dz * dz
				if distSq <= MAX_DRAW_DISTANCE then
					local cameraDist = sqrt(distSq)
					local alpha = max(0, 1 - age / DAMAGE_LIFETIME)
					local size = entry.critical and (DAMAGE_TEXT_SIZE + 2.5) or DAMAGE_TEXT_SIZE
					local s = cameraDist / SCREEN_REF_DISTANCE
					glPushMatrix()
					glTranslate(x, y + 24 + age * RISE_SPEED, z)
					glBillboard()
					glScale(s, s, s)
					drawText(entry.label, 0, 0, size, {entry.color[1], entry.color[2], entry.color[3], alpha}, "voco")
					glPopMatrix()
				end
			end
		end
	end
end

local function updateETAState(state, progress, now)
	if progress == nil then return end
	if state.lastProgress == nil then
		state.lastProgress = progress
		state.lastTime = now
		state.lastChangeTime = now
		return
	end
	local dt = now - (state.lastTime or now)
	if dt <= 0 then return end
	local dp = progress - state.lastProgress
	state.lastProgress = progress
	state.lastTime = now
	if abs(dp) < 0.00001 then
		if state.lastChangeTime and now - state.lastChangeTime > 2 then
			state.rate = nil
			state.timeLeft = nil
		end
		return
	end
	state.lastChangeTime = now
	local rate = dp / dt
	if state.rate and state.rate * rate > 0 then
		state.rate = state.rate * 0.7 + rate * 0.3
	else
		state.rate = rate
	end
	if state.rate > 0 then
		state.timeLeft = (1 - progress) / state.rate
	else
		-- Negative build progress means the unfinished unit is decaying.
		state.timeLeft = progress / state.rate
	end
end

local function addETAAndCostLabels(labels, info, buildProgress, isBuilding)
	if not isBuilding or buildProgress == nil then return end
	local meta = info.meta or {}
	local eta = info.eta
	if eta and eta.timeLeft and abs(eta.timeLeft) > 0.5 then
		if eta.timeLeft < 0 then
			addLabel(labels, "DECAYING " .. formatETA(abs(eta.timeLeft)), TEXT_COLORS.decaying)
		else
			addLabel(labels, "ETA " .. formatETA(eta.timeLeft), TEXT_COLORS.eta)
		end
	end
	if meta.metalCost > 0 or meta.energyCost > 0 then
		local metalLeft = ceil((1 - buildProgress) * meta.metalCost)
		local energyLeft = ceil((1 - buildProgress) * meta.energyCost)
		addLabel(labels, "M:" .. formatCount(metalLeft) .. " E:" .. formatCount(energyLeft), TEXT_COLORS.cost)
	end
end

-- Build a list of units that are going to be drawn this frame.  Keeping the
-- health/position sample in one pass avoids an extra GetUnitHealth call just
-- for de-duplication and makes the result stable for the subsequent draw.
local function collectVisibleUnitStates(cameraX, cameraY, cameraZ)
	local states = {}
	local sleepingUnits = {}
	local now = spGetGameSeconds()

	for unitID, info in pairs(trackedUnits) do
		local health, maxHealth, paralyzeDamage, capture, buildProgress = spGetUnitHealth(unitID)
		if health and maxHealth and maxHealth > 0 then
			local ux, uy, uz = spGetUnitViewPosition(unitID)
			if ux then
				local dx, dy, dz = ux - cameraX, uy - cameraY, uz - cameraZ
				if dx * dx + dy * dy + dz * dz < MAX_DRAW_DISTANCE then
					local currentSpeed
					if spGetUnitVelocity then
						local velocityX, velocityY, velocityZ = spGetUnitVelocity(unitID)
						currentSpeed = velocityX and sqrt(
							velocityX * velocityX
							+ (velocityY or 0) * (velocityY or 0)
							+ (velocityZ or 0) * (velocityZ or 0)
						) * GAME_SPEED or 0
					end
					local resourceFlow
					if spGetUnitResources then
						local metalMade, metalUsed, energyMade, energyUsed = spGetUnitResources(unitID)
						metalMade, metalUsed = metalMade or 0, metalUsed or 0
						energyMade, energyUsed = energyMade or 0, energyUsed or 0
						resourceFlow = {
							metalMade = metalMade,
							metalUsed = metalUsed,
							energyMade = energyMade,
							energyUsed = energyUsed,
							hasFlow = metalMade > 0.05 or metalUsed > 0.05
								or energyMade > 0.05 or energyUsed > 0.05,
						}
					end

					local teamID = spGetUnitTeam and spGetUnitTeam(unitID)
					local playerName, playerColor = getCachedTeam(teamID)
					local unitState = {
						unitID = unitID,
						info = info,
						defID = info.defID,
						teamID = teamID,
						x = ux,
						y = uy,
						z = uz,
						health = health,
						maxHealth = maxHealth,
						paralyzeDamage = paralyzeDamage,
						capture = capture,
						buildProgress = buildProgress,
						currentSpeed = currentSpeed,
						resourceFlow = resourceFlow,
						playerName = playerName,
						playerColor = playerColor,
					}

					if isUnitAwake(unitID, info.defID, health, maxHealth, currentSpeed, resourceFlow, paralyzeDamage, capture, buildProgress, now) then
						states[#states + 1] = unitState
					else
						sleepingUnits[#sleepingUnits + 1] = unitState
					end
				end
			end
		end
	end

	-- For sleeping/idle units: If 2 or more of the same unit type stand close together in a group, display text for 1 representative unit in the group!
	if #sleepingUnits > 0 then
		local groupRadius = SLEEP_GROUP_RADIUS
		local groupRadiusSq = groupRadius * groupRadius
		local cellSize = 155
		local buckets = {}

		for _, s in ipairs(sleepingUnits) do
			local cx = floor(s.x / cellSize)
			local cz = floor(s.z / cellSize)
			local col = buckets[cx]
			if not col then
				col = {}
				buckets[cx] = col
			end
			local bucket = col[cz]
			if not bucket then
				bucket = {}
				col[cz] = bucket
			end
			bucket[#bucket + 1] = s
		end

		for _, s in ipairs(sleepingUnits) do
			local cx = floor(s.x / cellSize)
			local cz = floor(s.z / cellSize)
			local clusterCount = 1
			local lowestUnitID = s.unitID

			for ox = -1, 1 do
				local col = buckets[cx + ox]
				if col then
					for oz = -1, 1 do
						local bucket = col[cz + oz]
						if bucket then
							for _, other in ipairs(bucket) do
								if other.unitID ~= s.unitID and other.defID == s.defID and other.teamID == s.teamID then
									local dx = other.x - s.x
									local dz = other.z - s.z
									if dx * dx + dz * dz <= groupRadiusSq then
										clusterCount = clusterCount + 1
										if other.unitID < lowestUnitID then
											lowestUnitID = other.unitID
										end
									end
								end
							end
						end
					end
				end
			end

			-- If there are 2 or more units in this group and this unit is the elected group representative, show text!
			if clusterCount >= 2 and s.unitID == lowestUnitID then
				states[#states + 1] = s
			end
		end
	end

	return states
end

local function suppressDuplicateUnitLabels(states)
	healthLabelSuppressed = {}
	speedLabelSuppressed = {}
	resourceLabelSuppressed = {}
	local buckets = {}
	local cellSize = SPEED_DEDUP_DISTANCE
	for _, state in ipairs(states) do
		-- No line exists to deduplicate when this unit has no speed/resource
		-- value, which also lets the neighbor scan stop early.
		if state.currentSpeed == nil then
			speedLabelSuppressed[state.unitID] = true
		end
		if not state.resourceFlow or not state.resourceFlow.hasFlow then
			resourceLabelSuppressed[state.unitID] = true
		end
	end

	-- Spatial buckets keep this near O(n) even when many units are visible.
	for _, state in ipairs(states) do
		local cellX = floor(state.x / cellSize)
		local cellZ = floor(state.z / cellSize)
		local column = buckets[cellX]
		if not column then
			column = {}
			buckets[cellX] = column
		end
		local bucket = column[cellZ]
		if not bucket then
			bucket = {}
			column[cellZ] = bucket
		end
		bucket[#bucket + 1] = state
	end

	for _, state in ipairs(states) do
		if not healthLabelSuppressed[state.unitID]
			or not speedLabelSuppressed[state.unitID]
			or not resourceLabelSuppressed[state.unitID] then
			local cellX = floor(state.x / cellSize)
			local cellZ = floor(state.z / cellSize)
			for offsetX = -1, 1 do
				local column = buckets[cellX + offsetX]
				if column then
					for offsetZ = -1, 1 do
						local bucket = column[cellZ + offsetZ]
						if bucket then
							for _, other in ipairs(bucket) do
								-- The lowest unitID owns the shared label, so the
								-- result does not depend on pairs() iteration order.
								if other.unitID < state.unitID and other.defID == state.defID then
									local dx = other.x - state.x
									local dz = other.z - state.z
									local distSq = dx * dx + dz * dz

									-- Health and resource flow deduplication
									if distSq <= HP_DEDUP_DISTANCE_SQ then
										if abs(other.health - state.health) <= HP_EQUAL_EPSILON
											and abs(other.maxHealth - state.maxHealth) <= HP_EQUAL_EPSILON then
											healthLabelSuppressed[state.unitID] = true
										end
										local otherFlow, stateFlow = other.resourceFlow, state.resourceFlow
										if otherFlow and stateFlow and otherFlow.hasFlow and stateFlow.hasFlow
											and abs(otherFlow.metalMade - stateFlow.metalMade) <= RESOURCE_EQUAL_EPSILON
											and abs(otherFlow.metalUsed - stateFlow.metalUsed) <= RESOURCE_EQUAL_EPSILON
											and abs(otherFlow.energyMade - stateFlow.energyMade) <= RESOURCE_EQUAL_EPSILON
											and abs(otherFlow.energyUsed - stateFlow.energyUsed) <= RESOURCE_EQUAL_EPSILON then
											resourceLabelSuppressed[state.unitID] = true
										end
									end

									-- Group speed deduplication for same unit types:
									-- Only one unit in a moving group of identical units displays SPEED.
									if distSq <= SPEED_DEDUP_DISTANCE_SQ then
										if other.currentSpeed ~= nil and state.currentSpeed ~= nil
											and other.currentSpeed > 0.8 and state.currentSpeed > 0.8 then
											speedLabelSuppressed[state.unitID] = true
										end
									end

									if healthLabelSuppressed[state.unitID]
										and speedLabelSuppressed[state.unitID]
										and resourceLabelSuppressed[state.unitID] then
										break
									end
								end
							end
						end
						if healthLabelSuppressed[state.unitID]
							and speedLabelSuppressed[state.unitID]
							and resourceLabelSuppressed[state.unitID] then break end
					end
				end
				if healthLabelSuppressed[state.unitID]
					and speedLabelSuppressed[state.unitID]
					and resourceLabelSuppressed[state.unitID] then break end
			end
		end
	end
end

local function collectUnitLabels(unitID, info, health, maxHealth, paralyzeDamage, capture, buildProgress, isBuilding, currentSpeed, resourceFlow, showHealth, showSpeed, showResource, playerName, playerColor, showPlayerName)
	local labels = {}
	local hp = clampPercent(health / maxHealth)
	if showHealth ~= false then
		addLabel(labels, string.format("HP %s/%s", formatThousands(health), formatThousands(maxHealth)), healthTextColor(hp))
	end

	local meta = info.meta or {}
	-- Only show SPEED when the unit is actively moving (hide SPEED completely when stationary)
	if meta.speed and meta.speed > 0.05 and currentSpeed and currentSpeed > 0.8 and showSpeed ~= false then
		addLabel(labels, "SPEED " .. formatRateMagnitude(currentSpeed), TEXT_COLORS.speed)
	end
	if resourceFlow and resourceFlow.hasFlow and showResource ~= false then
		addLabel(labels, "M:" .. formatResourceFlow(resourceFlow.metalMade, resourceFlow.metalUsed)
			.. " E:" .. formatResourceFlow(resourceFlow.energyMade, resourceFlow.energyUsed), TEXT_COLORS.resource)
	end
	if meta.shieldMax and spGetUnitShieldState then
		local shieldOn, shieldPower = spGetUnitShieldState(unitID)
		if shieldPower then
			if shieldOn == false then shieldPower = 0 end
			-- Always show the current value and maximum capacity, including when
			-- the shield is full, so the unit's shield capacity is never hidden.
			addLabel(labels, string.format("SHIELD %s/%s", formatThousands(shieldPower), formatThousands(meta.shieldMax)), TEXT_COLORS.shield)
		end
	end
	if capture and capture > 0 then
		addLabel(labels, string.format("CAPTURE %d%%", floor(clampPercent(capture) * 100 + 0.5)), TEXT_COLORS.capture)
	end
	if meta.canStockpile and spGetUnitStockpile then
		local stockpiled, queued, stockpileBuild = spGetUnitStockpile(unitID)
		if stockpiled ~= nil then
			addLabel(labels, string.format("STOCK %s +%s (%d%%)", formatThousands(stockpiled), formatThousands(queued or 0), floor(clampPercent(stockpileBuild) * 100 + 0.5)), TEXT_COLORS.stockpile)
		end
	end
	if paralyzeDamage and paralyzeDamage > 0 then
		local isStunned = spGetUnitIsStunned and spGetUnitIsStunned(unitID)
		local labelName = isStunned and "PARALYZED" or "EMP"
		local color = isStunned and TEXT_COLORS.paralyzed or TEXT_COLORS.emp
		addLabel(labels, string.format("%s %s/%s", labelName, formatThousands(paralyzeDamage), formatThousands(maxHealth)), color)
	end
	if meta.primaryWeapon and spGetUnitWeaponState then
		local reloadFrame = spGetUnitWeaponState(unitID, meta.primaryWeapon, "reloadFrame")
		if reloadFrame and reloadFrame > spGetGameFrame() then
			addLabel(labels, "RELOAD " .. formatSeconds((reloadFrame - spGetGameFrame()) / 30), TEXT_COLORS.reload)
		end
	end
	if buildProgress and buildProgress < 0.995 then
		addLabel(labels, string.format("BUILD %d%%", floor(clampPercent(buildProgress) * 100 + 0.5)), TEXT_COLORS.building)
	end
	addETAAndCostLabels(labels, info, buildProgress, isBuilding)
	if meta.isHero and playerName and showPlayerName ~= false then
		addLabel(labels, playerName, playerColor or TEXT_COLORS.player)
	end
	return labels
end

function widget:ViewResize()
	if WG.fonts then
		font = WG.fonts.getFont(nil, 1.2, 0.2, 20)
	end
end

function widget:Initialize()
	-- Disable every stock health/progress bar type; the labels below remain.
	hideStockBars()
	teamCache = {}
	local _, currentFullview = spGetSpectatingState()
	fullview = currentFullview
	myAllyTeam = spGetMyAllyTeamID()
	cacheUnitDefs()
	widget:ViewResize()
	rebuildUnitList()
end

local function getFeatureProgress(featureID)
	local _, _, _, _, reclaimLeft = spGetFeatureResources(featureID)
	local _, _, resurrectProgress = spGetFeatureHealth(featureID)
	if reclaimLeft and reclaimLeft < 0.999 then
		return reclaimLeft
	end
	if resurrectProgress and resurrectProgress > 0.001 and resurrectProgress < 0.999 then
		return resurrectProgress
	end
	return nil
end

local function updateETAStates(now)
	for unitID, info in pairs(trackedUnits) do
		local isBuilding, progress = spGetUnitIsBeingBuilt(unitID)
		if isBuilding and progress ~= nil then
			updateETAState(info.eta, progress, now)
		else
			info.eta = {}
		end
	end
	activeDamagedFeatures = {}
	for featureID, info in pairs(trackedFeatures) do
		local progress = getFeatureProgress(featureID)
		local featureHealth, featureMaxHealth = spGetFeatureHealth(featureID)
		local isDamaged = featureHealth and featureMaxHealth and featureHealth < featureMaxHealth * 0.999
		if progress ~= nil or isDamaged then
			if progress ~= nil then
				updateETAState(info.eta, progress, now)
			else
				info.eta = {}
			end
			activeDamagedFeatures[#activeDamagedFeatures + 1] = featureID
		else
			info.eta = {}
		end
	end
end

function widget:PlayerChanged()
	teamCache = {}
	local _, currentFullview = spGetSpectatingState()
	fullview = currentFullview
	myAllyTeam = spGetMyAllyTeamID()
	rebuildUnitList()
	shieldSnapshots = {}
	updateShieldSnapshots()
end

function widget:Update()
	local now = spGetGameSeconds()
	if now - lastStateCheck < UPDATE_SECONDS then return end
	lastStateCheck = now
	updateETAStates(now)
	local _, currentFullview = spGetSpectatingState()
	if currentFullview ~= fullview or spGetMyAllyTeamID() ~= myAllyTeam then
		teamCache = {}
		fullview = currentFullview
		myAllyTeam = spGetMyAllyTeamID()
		rebuildUnitList()
	end
	updateShieldSnapshots()
end

function widget:UnitCreated(unitID, unitDefID)
	unitLastActiveTime[unitID] = spGetGameSeconds()
	addUnit(unitID, unitDefID)
end

function widget:UnitGiven(unitID, unitDefID)
	unitLastActiveTime[unitID] = spGetGameSeconds()
	addUnit(unitID, unitDefID)
end

function widget:UnitDestroyed(unitID)
	unitLastActiveTime[unitID] = nil
	unitLastHealth[unitID] = nil
	trackedUnits[unitID] = nil
end

function widget:FeatureCreated(featureID)
	addFeature(featureID)
end

function widget:FeatureDestroyed(featureID)
	trackedFeatures[featureID] = nil
end

function widget:UnitTaken(unitID, unitDefID)
	if fullview or canSeeUnit(unitID) then
		addUnit(unitID, unitDefID)
	else
		trackedUnits[unitID] = nil
		unitLastActiveTime[unitID] = nil
		unitLastHealth[unitID] = nil
	end
end

function widget:DrawWorld()
	if spIsGUIHidden() then return end

	local cameraX, cameraY, cameraZ = Spring.GetCameraPosition()
	local glStateReady = false
	local visibleUnitStates = collectVisibleUnitStates(cameraX, cameraY, cameraZ)
	suppressDuplicateUnitLabels(visibleUnitStates)
	local activeUnitLabels = {}
	for _, state in ipairs(visibleUnitStates) do
		local unitID, info = state.unitID, state.info
		local dx, dy, dz = state.x - cameraX, state.y - cameraY, state.z - cameraZ
		local cameraDist = sqrt(dx * dx + dy * dy + dz * dz)
		local isBuilding, currentBuild = spGetUnitIsBeingBuilt(unitID)
		local buildProgress = state.buildProgress
		if isBuilding then buildProgress = currentBuild or buildProgress end
		local yoffset = info.height + SYSTEM_BAR_OFFSET + LABEL_RAISE
		local labels = collectUnitLabels(
			unitID,
			info,
			state.health,
			state.maxHealth,
			state.paralyzeDamage,
			state.capture,
			buildProgress,
			isBuilding,
			state.currentSpeed,
			state.resourceFlow,
			not healthLabelSuppressed[unitID],
			not speedLabelSuppressed[unitID],
			not resourceLabelSuppressed[unitID],
			state.playerName,
			state.playerColor,
			not healthLabelSuppressed[unitID]
		)
		if #labels > 0 then
			local sx, sy, sz = Spring.WorldToScreenCoords(state.x, state.y + yoffset, state.z)
			activeUnitLabels[#activeUnitLabels + 1] = {
				unitID = unitID,
				labels = labels,
				yoffset = yoffset,
				cameraDist = cameraDist,
				sx = sx or 0,
				sy = sy or 0,
				sz = sz or 0,
				offsetX = 0,
				offsetY = 0,
			}
		end
	end

	-- Smart Anti-Collision: Sorted Y-Window algorithm (O(N log N) / O(N))
	local numActive = #activeUnitLabels
	if numActive > 1 then
		table.sort(activeUnitLabels, function(a, b) return a.sy < b.sy end)
		local minDistX = 48
		local minDistY = 22
		for iter = 1, 2 do
			for i = 1, numActive do
				local a = activeUnitLabels[i]
				local aY = a.sy + a.offsetY
				local aX = a.sx + a.offsetX
				for j = i + 1, numActive do
					local b = activeUnitLabels[j]
					local bY = b.sy + b.offsetY
					local cdy = aY - bY
					if abs(cdy) >= minDistY and (b.sy - a.sy) >= minDistY * 2 then
						break -- No subsequent label in the sorted array can collide vertically
					end
					local cdx = aX - (b.sx + b.offsetX)
					if abs(cdx) < minDistX and abs(cdy) < minDistY then
						if abs(cdx) < 0.1 then
							cdx = (a.unitID > b.unitID) and 1.0 or -1.0
						end
						local overlapX = minDistX - abs(cdx)
						local pushX = overlapX * 0.52 * (cdx > 0 and 1 or -1)
						a.offsetX = a.offsetX + pushX
						b.offsetX = b.offsetX - pushX

						local overlapY = minDistY - abs(cdy)
						local pushY = overlapY * 0.30 * (cdy >= 0 and 1 or -1)
						a.offsetY = a.offsetY + pushY
						b.offsetY = b.offsetY - pushY

						aY = a.sy + a.offsetY
						aX = a.sx + a.offsetX
					end
				end
			end
		end
	end

	-- Render all resolved unit labels
	for i = 1, numActive do
		local item = activeUnitLabels[i]
		if not glStateReady then
			glDepthTest(true)
			glStateReady = true
		end
		glDrawFuncAtUnit(item.unitID, false, drawLabels, item.labels, item.yoffset, item.cameraDist, item.offsetX, item.offsetY)
	end

	-- Render active/damaged features only (Culled from thousands of static map features)
	for fIdx = 1, #activeDamagedFeatures do
		local featureID = activeDamagedFeatures[fIdx]
		local info = trackedFeatures[featureID]
		if info then
			local fx, fy, fz = spGetFeaturePosition(featureID)
		if fx and (fullview or not spIsPosInLos or spIsPosInLos(fx, fy, fz, myAllyTeam)) then
			local dx, dy, dz = fx - cameraX, fy - cameraY, fz - cameraZ
			local distSq = dx * dx + dy * dy + dz * dz
			if distSq < MAX_DRAW_DISTANCE then
				local cameraDist = sqrt(distSq)
				local featureHealth, featureMaxHealth, resurrectProgress = spGetFeatureHealth(featureID)
				local labels = {}
				if featureHealth and featureMaxHealth and featureMaxHealth > 0
					and featureHealth < featureMaxHealth * 0.999 then
					addLabel(labels, string.format("FHP %s/%s", formatThousands(featureHealth), formatThousands(featureMaxHealth)), TEXT_COLORS.featureHealth)
				end
				if spGetFeatureResources then
					local metalLeft, maxMetal, energyLeft, maxEnergy = spGetFeatureResources(featureID)
					-- Features such as wrecks, trees and rocks can carry reclaimable
					-- metal and/or energy.  Keep the readout numeric and visible even
					-- when the feature is otherwise at full health.
					if (maxMetal and maxMetal > 0) or (maxEnergy and maxEnergy > 0) then
						addLabel(labels, "M:" .. formatCount(metalLeft or 0) .. " E:" .. formatCount(energyLeft or 0), TEXT_COLORS.cost)
					end
					if metalLeft and maxMetal and maxMetal > 0 and metalLeft < maxMetal then
						local reclaimProgress = 1 - clampPercent(metalLeft / maxMetal)
						addLabel(labels, string.format("RECLAIM %d%%", floor(reclaimProgress * 100 + 0.5)), TEXT_COLORS.reclaim)
					end
				end
				if resurrectProgress and resurrectProgress > 0 then
					addLabel(labels, string.format("RESURRECT %d%%", floor(clampPercent(resurrectProgress) * 100 + 0.5)), TEXT_COLORS.resurrect)
				end
				local eta = info.eta
				if eta and eta.timeLeft and abs(eta.timeLeft) > 0.5 then
					addLabel(labels, "ETA " .. formatETA(abs(eta.timeLeft)), TEXT_COLORS.eta)
				end
				if #labels > 0 then
					if not glStateReady then
						glDepthTest(true)
						glStateReady = true
					end
					glPushMatrix()
					glTranslate(fx, fy + (info.height or 32) + SYSTEM_BAR_OFFSET + LABEL_RAISE, fz)
					drawLabels(labels, 0, cameraDist)
					glPopMatrix()
				end
			end
		end
	end
	end
	-- Draw floating RPG damage and shield numbers
	drawDamageNumbers(cameraX, cameraY, cameraZ)

	if glStateReady then
		glColor(1, 1, 1, 1)
		glDepthTest(false)
	end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer)
	unitLastActiveTime[unitID] = spGetGameSeconds()
	pushDamageNumber(unitID, unitTeam, damage, paralyzer)
end

function widget:Shutdown()
	trackedUnits = {}
	trackedFeatures = {}
	teamCache = {}
	healthLabelSuppressed = {}
	speedLabelSuppressed = {}
	resourceLabelSuppressed = {}
	damageNumbers = {}
	shieldSnapshots = {}
	unitLastActiveTime = {}
	unitLastHealth = {}
end
