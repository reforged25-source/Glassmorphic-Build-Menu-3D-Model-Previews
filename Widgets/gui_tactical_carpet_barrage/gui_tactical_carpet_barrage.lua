local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Tactical Carpet Barrage & TOT",
		desc = "AAA-grade Synchronized Time-On-Target (TOT) and non-overlapping carpet bombardment for artillery, rockets, and missile silos with real-time damage tier color telemetry and out-of-range visual alerts.",
		author = "reforged25-source / Codex",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = true,
		handler = true,
	}
end

--------------------------------------------------------------------------------
-- SPEEDUPS & ENGINE REFERENCES
--------------------------------------------------------------------------------
local spGetSelectedUnits       = Spring.GetSelectedUnits
local spGetUnitDefID           = Spring.GetUnitDefID
local spGetUnitPosition        = Spring.GetUnitPosition
local spGetUnitHeading         = Spring.GetUnitHeading
local spGetUnitStockpile       = Spring.GetUnitStockpile
local spGetUnitCmdDescs        = Spring.GetUnitCmdDescs
local spGetGroundHeight        = Spring.GetGroundHeight
local spTraceScreenRay         = Spring.TraceScreenRay
local spGetActiveCommand       = Spring.GetActiveCommand
local spGetActiveCmdDesc       = Spring.GetActiveCmdDesc
local spSetActiveCommand       = Spring.SetActiveCommand
local spGiveOrderToUnit        = Spring.GiveOrderToUnit
local spGetGameFrame           = Spring.GetGameFrame
local spGetGameSeconds         = Spring.GetGameSeconds
local spGetViewGeometry        = Spring.GetViewGeometry
local spGetModKeyState         = Spring.GetModKeyState
local spPlaySoundFile          = Spring.PlaySoundFile
local spIsGUIHidden            = Spring.IsGUIHidden
local spEcho                   = Spring.Echo
local spWorldToScreenCoords    = Spring.WorldToScreenCoords

local glColor                  = gl.Color
local glLineWidth              = gl.LineWidth
local glBeginEnd               = gl.BeginEnd
local glVertex                 = gl.Vertex
local glDepthTest              = gl.DepthTest
local glText                   = gl.Text
local glRect                   = gl.Rect

local GL_LINES                 = GL.LINES
local GL_LINE_STRIP            = GL.LINE_STRIP
local GL_LINE_LOOP             = GL.LINE_LOOP
local GL_TRIANGLE_FAN          = GL.TRIANGLE_FAN

local max                      = math.max
local min                      = math.min
local sqrt                     = math.sqrt
local abs                      = math.abs
local sin                      = math.sin
local cos                      = math.cos
local atan2                    = math.atan2
local floor                    = math.floor
local ceil                     = math.ceil
local pi                       = math.pi
local TWO_PI                   = math.pi * 2
local DEG_TO_RAD               = math.pi / 180
local SPRING_HEADING_SCALE     = (2 * math.pi) / 65536

--------------------------------------------------------------------------------
-- COMMAND IDENTIFIERS & PHYSICS CONSTANTS
--------------------------------------------------------------------------------
local CMD_ATTACK               = CMD.ATTACK or 16
local CMD_SET_TARGET           = (CMD and CMD.SET_TARGET) or 34923
local CMD_MANUALFIRE           = (CMD and CMD.MANUALFIRE) or 20
local CMD_STOCKPILE            = (CMD and CMD.STOCKPILE) or 100

local DRAG_PIXEL_THRESHOLD     = 8 -- Screen pixels before engaging carpet barrage
local ENGINE_GRAVITY           = (Game and Game.gravity) or 130.0

-- Pre-computed Trigonometric Table (48 Segments) for Zero-GC Rendering
local CIRCLE_SEGMENTS          = 48
local CIRCLE_COS               = {}
local CIRCLE_SIN               = {}
for i = 0, CIRCLE_SEGMENTS do
	local angle = (i / CIRCLE_SEGMENTS) * TWO_PI
	CIRCLE_COS[i] = cos(angle)
	CIRCLE_SIN[i] = sin(angle)
end

--------------------------------------------------------------------------------
-- DAMAGE TELEMETRY & TIER COLOR HIERARCHY
--------------------------------------------------------------------------------
-- Tier 0: EMP / Paralyzer           -> Electric Cyan       (0.18, 0.85, 1.00)
-- Tier 1: Light Kinetic (< 500)      -> Emerald Mint Green  (0.20, 0.95, 0.55)
-- Tier 2: High Explosive (500-1499)  -> Tactical Amber/Gold (1.00, 0.82, 0.15)
-- Tier 3: Heavy Siege (1500-4999)    -> Fiery Magma Orange  (1.00, 0.42, 0.08)
-- Tier 4: Apocalyptic/Nuke (>= 5000) -> Plasma Crimson/Pink (1.00, 0.14, 0.42)
-- OUT OF RANGE ALERT                -> Flashing Crimson Red (1.00, 0.15, 0.15)

local function FormatNumberCommas(n)
	if not n then return "0" end
	n = floor(n + 0.5)
	local str = tostring(n)
	local formatted = ""
	local len = #str
	for i = 1, len do
		formatted = formatted .. str:sub(i, i)
		if (len - i) > 0 and (len - i) % 3 == 0 then
			formatted = formatted .. ","
		end
	end
	return formatted
end

local function GetDamageProfile(damage, isParalyzer)
	if isParalyzer then
		return {
			tag         = "EMP DISCHARGE",
			tierName    = "ELECTROMAGNETIC",
			shortLabel  = "EMP",
			tier        = 0,
			r = 0.18, g = 0.85, b = 1.00,
			glowR = 0.35, glowG = 0.92, glowB = 1.00,
			isEMP       = true,
		}
	end

	if damage >= 5000 then
		return {
			tag         = "APOCALYPTIC NUCLEAR",
			tierName    = "EXTREME DESTRUCTION",
			shortLabel  = "NUCLEAR",
			tier        = 4,
			r = 1.00, g = 0.14, b = 0.42,
			glowR = 1.00, glowG = 0.30, glowB = 0.55,
			isEMP       = false,
		}
	elseif damage >= 1500 then
		return {
			tag         = "HEAVY SIEGE",
			tierName    = "HEAVY DEVASTATION",
			shortLabel  = "HEAVY",
			tier        = 3,
			r = 1.00, g = 0.42, b = 0.08,
			glowR = 1.00, glowG = 0.58, glowB = 0.20,
			isEMP       = false,
		}
	elseif damage >= 500 then
		return {
			tag         = "HIGH EXPLOSIVE",
			tierName    = "TACTICAL SATURATION",
			shortLabel  = "HE",
			tier        = 2,
			r = 1.00, g = 0.82, b = 0.15,
			glowR = 1.00, glowG = 0.90, glowB = 0.35,
			isEMP       = false,
		}
	else
		return {
			tag         = "LIGHT KINETIC",
			tierName    = "PRECISION STRIKE",
			shortLabel  = "KINETIC",
			tier        = 1,
			r = 0.20, g = 0.95, b = 0.55,
			glowR = 0.40, glowG = 1.00, glowB = 0.70,
			isEMP       = false,
		}
	end
end

--------------------------------------------------------------------------------
-- STATE VARIABLES
--------------------------------------------------------------------------------
local isDragging               = false
local dragStartScreen          = { x = 0, y = 0 }
local dragStartWorld           = nil
local dragCurrentWorld         = nil
local dragCommandID            = CMD_ATTACK
local dragTargetUnitID         = nil
local dragShiftHeld            = false
local hasDraggedPastThreshold  = false
local isAreaMode               = false
local hadRangeViolationLast    = false

local activeBarragePreview     = nil
local pendingSalvos            = {}
local unitWeaponCache          = {}

--------------------------------------------------------------------------------
-- EXACT COMMAND RESOLVER & DETECTOR
--------------------------------------------------------------------------------
local function IsCarpetCapableCommand(cmdID, cmdName, cmdIndex)
	if cmdID and (cmdID == CMD_ATTACK or cmdID == 16 or cmdID == CMD_SET_TARGET or cmdID == 34923 or cmdID == CMD_MANUALFIRE or cmdID == 20) then
		return true
	end

	-- Check active command descriptor using cmdIndex
	if cmdIndex and spGetActiveCmdDesc then
		local ok, desc = pcall(spGetActiveCmdDesc, cmdIndex)
		if ok and desc then
			if desc.name then
				local s = string.lower(desc.name)
				if s:find("launch") or s:find("attack") or s:find("target") or s:find("fire") then
					return true
				end
			end
			if desc.action then
				local a = string.lower(desc.action)
				if a:find("launch") or a:find("attack") or a:find("target") or a:find("manualfire") then
					return true
				end
			end
		end
	end

	if cmdName then
		local s = string.lower(cmdName)
		if s:find("launch") or s:find("attack") or s:find("target") or s:find("fire") then
			return true
		end
	end

	return false
end

--------------------------------------------------------------------------------
-- WEAPON & DAMAGE INTEL ENGINE (EXTRACTS RAW DAMAGE, RANGE, AOE & PARALYSIS)
--------------------------------------------------------------------------------
local function GetUnitWeaponInfo(unitDefID)
	if unitWeaponCache[unitDefID] ~= nil then
		return unitWeaponCache[unitDefID]
	end

	local udef = UnitDefs[unitDefID]
	if not udef then
		unitWeaponCache[unitDefID] = false
		return false
	end

	-- 1. Check if unit is a Missile Silo (Nuke Silo / Tactical Missile / Juno / EMP Silo)
	if udef.canStockpile then
		local bestWeapon = nil
		if udef.weapons and #udef.weapons > 0 then
			-- Scan specifically for the stockpiled weapon
			for i = 1, #udef.weapons do
				local w = udef.weapons[i]
				if w and w.weaponDef then
					local wdef = WeaponDefs[w.weaponDef]
					if wdef and wdef.stockpile then
						bestWeapon = wdef
						break
					end
				end
			end
			-- Fallback to first non-shield weapon if not explicitly flagged
			if not bestWeapon then
				for i = 1, #udef.weapons do
					local w = udef.weapons[i]
					if w and w.weaponDef then
						local wdef = WeaponDefs[w.weaponDef]
						if wdef and not wdef.isShield then
							bestWeapon = wdef
							break
						end
					end
				end
			end
		end

		local aoeRadius = (bestWeapon and bestWeapon.damageAreaOfEffect) or 400

		-- Damage calculation
		local dmg = 0
		if bestWeapon then
			if bestWeapon.customParams and bestWeapon.customParams.damagew1 then
				dmg = tonumber(bestWeapon.customParams.damagew1) or 0
			elseif bestWeapon.damages then
				dmg = tonumber(bestWeapon.damages[1] or bestWeapon.damages[0] or bestWeapon.damages.default) or 0
			end
		end
		local burst = tonumber(bestWeapon and (bestWeapon.salvoSize or bestWeapon.projectiles) or 1) or 1
		local totalBurstDmg = floor(dmg * burst)
		if totalBurstDmg <= 0 then
			totalBurstDmg = 12500 -- Default nuclear ICBM payload
		end

		local isEMP = bestWeapon and (bestWeapon.paralyzer == true
			or (bestWeapon.damages and bestWeapon.damages.paralyzerDamageTime and bestWeapon.damages.paralyzerDamageTime > 0)
			or (bestWeapon.customParams and bestWeapon.customParams.extra_damage_paralyzer)) or false

		local dmgProfile = GetDamageProfile(totalBurstDmg, isEMP)

		local info = {
			name               = (bestWeapon and bestWeapon.name) or "Strategic Missile",
			range              = (bestWeapon and bestWeapon.range) or 72000,
			minRange           = (bestWeapon and bestWeapon.minRange) or 0,
			aoe                = max(120, aoeRadius),
			projSpeed          = max(200, (bestWeapon and bestWeapon.projectilespeed) or 350),
			reloadTime         = max(6.0, (bestWeapon and bestWeapon.reload) or 15.0),
			damage             = totalBurstDmg,
			isParalyzer        = isEMP,
			damageProfile      = dmgProfile,
			isBallistic        = false,
			highTraj           = true,
			turnRate           = 1.0,
			isSilo             = true,
			isImmobile         = udef.isImmobile or udef.isBuilding or (udef.speed and udef.speed < 0.1),
			verticalClimbTime  = 8.5,
		}
		unitWeaponCache[unitDefID] = info
		return info
	end

	-- 2. Standard Artillery, Rockets, Tanks, Combat Units
	if not udef.weapons or #udef.weapons == 0 then
		unitWeaponCache[unitDefID] = false
		return false
	end

	local bestWeapon = nil
	local maxRange = 0

	for i = 1, #udef.weapons do
		local w = udef.weapons[i]
		if w and w.weaponDef then
			local wdef = WeaponDefs[w.weaponDef]
			if wdef and wdef.range and wdef.range > maxRange then
				local isAAOnly = wdef.onlyTargets and (wdef.onlyTargets.air == true or wdef.onlyTargets.vtol == true) and not wdef.onlyTargets.ground
				if not isAAOnly and not wdef.isShield then
					maxRange = wdef.range
					bestWeapon = wdef
				end
			end
		end
	end

	if not bestWeapon and udef.weapons[1] and udef.weapons[1].weaponDef then
		bestWeapon = WeaponDefs[udef.weapons[1].weaponDef]
	end

	if not bestWeapon then
		unitWeaponCache[unitDefID] = false
		return false
	end

	-- Damage calculation
	local dmg = 0
	if bestWeapon.customParams and bestWeapon.customParams.damagew1 then
		dmg = tonumber(bestWeapon.customParams.damagew1) or 0
	elseif bestWeapon.damages then
		dmg = tonumber(bestWeapon.damages[1] or bestWeapon.damages[0] or bestWeapon.damages.default) or 0
	end
	local burst = tonumber(bestWeapon.salvoSize or bestWeapon.projectiles or 1) or 1
	local totalBurstDmg = floor(dmg * burst)
	if totalBurstDmg <= 0 then
		totalBurstDmg = 350 -- Standard shell fallback
	end

	local isEMP = (bestWeapon.paralyzer == true)
		or (bestWeapon.damages and bestWeapon.damages.paralyzerDamageTime and bestWeapon.damages.paralyzerDamageTime > 0)
		or (bestWeapon.customParams and bestWeapon.customParams.extra_damage_paralyzer) or false

	local dmgProfile = GetDamageProfile(totalBurstDmg, isEMP)

	local info = {
		name               = bestWeapon.name or "Cannon",
		range              = bestWeapon.range or 600,
		minRange           = bestWeapon.minRange or 0,
		aoe                = max(28, bestWeapon.damageAreaOfEffect or 32),
		projSpeed          = max(120, bestWeapon.projectilespeed or 350),
		reloadTime         = max(1.0, bestWeapon.reload or 3.5),
		damage             = totalBurstDmg,
		isParalyzer        = isEMP,
		damageProfile      = dmgProfile,
		isBallistic        = (bestWeapon.type == "Cannon" or bestWeapon.type == "MissileLauncher"),
		highTraj           = bestWeapon.trajectoryHeight and (bestWeapon.trajectoryHeight > 0),
		turnRate           = max(0.2, (udef.turnRate or 300) * DEG_TO_RAD),
		isSilo             = false,
		isImmobile         = udef.isImmobile or udef.isBuilding or (udef.speed and udef.speed < 0.1),
		verticalClimbTime  = 0,
	}

	unitWeaponCache[unitDefID] = info
	return info
end

--------------------------------------------------------------------------------
-- RIGOROUS BALLISTIC & ICBM FLIGHT SOLVER
--------------------------------------------------------------------------------
local function SolveFlightTime(dx, dy, dz, winfo)
	local horizDist = sqrt(dx * dx + dz * dz)
	if horizDist <= 1 then return 0.1 end

	-- 1. ICBM / Strategic Silo Missiles (Vertical Climb Phase + Horizontal Cruise)
	if winfo.isSilo then
		local cruiseTime = horizDist / winfo.projSpeed
		return max(2.0, winfo.verticalClimbTime + cruiseTime)
	end

	-- 2. Direct-fire / Laser / Supersonic Missiles
	if not winfo.isBallistic then
		local totalDist = sqrt(horizDist * horizDist + dy * dy)
		return max(0.1, totalDist / winfo.projSpeed)
	end

	-- 3. True Parabolic Closed-Form Trajectory under Engine Gravity
	local g = ENGINE_GRAVITY
	local v = winfo.projSpeed
	local v2 = v * v
	local v4 = v2 * v2

	local discriminant = v4 - g * (g * horizDist * horizDist + 2 * dy * v2)
	if discriminant < 0 then
		local totalDist = sqrt(horizDist * horizDist + dy * dy)
		return max(0.1, totalDist / v)
	end

	local sqrtDisc = sqrt(discriminant)
	local root = winfo.highTraj and (v2 + sqrtDisc) or (v2 - sqrtDisc)
	local theta = atan2(root, g * horizDist)
	local cosTheta = cos(theta)

	local vHoriz = max(10, v * cosTheta)
	return max(0.1, horizDist / vHoriz)
end

local function SolveTurretSlewTime(unitX, unitZ, unitHeadingSpring, targetX, targetZ, turnRate)
	local desiredAngle = atan2(targetX - unitX, targetZ - unitZ)
	local currentAngle = unitHeadingSpring * SPRING_HEADING_SCALE

	local diff = desiredAngle - currentAngle
	while diff > pi do diff = diff - TWO_PI end
	while diff < -pi do diff = diff + TWO_PI end

	return abs(diff) / max(0.1, turnRate)
end

--------------------------------------------------------------------------------
-- RAYCAST GROUND HELPER
--------------------------------------------------------------------------------
local function GetGroundPosFromMouse(mx, my)
	local traceType, pos = spTraceScreenRay(mx, my, false, false, false)
	local targetID = nil
	if traceType == "unit" and pos then
		targetID = pos
		local ux, uy, uz = spGetUnitPosition(targetID)
		if ux then
			return { ux, uy, uz }, targetID
		end
	end

	local _, gpos = spTraceScreenRay(mx, my, true, false, false)
	if gpos then
		return gpos, nil
	end
	return nil, nil
end

--------------------------------------------------------------------------------
-- SPATIAL TESSELLATION & CLOSE PACKING (LINEAR & A2 HEXAGONAL LATTICE)
--------------------------------------------------------------------------------
local function GenerateLinearTessellation(pStart, pEnd, count, avgAoE, batteryCenter)
	local points = {}
	if count <= 0 then return points, 0, 0 end

	local gy = spGetGroundHeight(pStart[1], pStart[3])
	if count == 1 then
		points[1] = { pStart[1], gy, pStart[3], row = 1, col = 1 }
		return points, 1, 1
	end

	local dx = pEnd[1] - pStart[1]
	local dz = pEnd[3] - pStart[3]
	local totalDist = sqrt(dx * dx + dz * dz)

	local minStep = max(30, avgAoE * 1.85)

	-- If totalDist is nearly zero (clicked in place or tiny drag < 10 elmos)
	if totalDist < 10 then
		local cols = ceil(sqrt(count))
		local rows = ceil(count / cols)
		local halfCols = (cols - 1) * 0.5
		local halfRows = (rows - 1) * 0.5
		local rowH = minStep * 0.866025

		for i = 0, count - 1 do
			local r = floor(i / cols)
			local c = i % cols
			local stagger = (r % 2 == 1) and (minStep * 0.5) or 0
			local tx = pStart[1] + (c - halfCols) * minStep + stagger
			local tz = pStart[3] + (r - halfRows) * rowH
			local ty = spGetGroundHeight(tx, tz)
			points[#points + 1] = { tx, ty, tz, row = r + 1, col = c + 1 }
		end
		return points, cols, rows
	end

	local ux = dx / totalDist
	local uz = dz / totalDist

	-- Normal vector pointing perpendicular to drag line
	local nx = -uz
	local nz = ux

	-- Orient normal vector so it extends away from the artillery battery (creeping forward)
	if batteryCenter then
		local toTargetX = pStart[1] - batteryCenter[1]
		local toTargetZ = pStart[3] - batteryCenter[3]
		if (nx * toTargetX + nz * toTargetZ) < 0 then
			nx = -nx
			nz = -nz
		end
	end

	-- How many blast points can fit in 1 row along totalDist without overlapping?
	local maxCols = max(1, floor(totalDist / minStep + 0.5) + 1)

	-- If all points fit in a single row without overlapping:
	if maxCols >= count then
		local stepFrac = 1.0 / (count - 1)
		for i = 0, count - 1 do
			local frac = i * stepFrac
			local tx = pStart[1] + dx * frac
			local tz = pStart[3] + dz * frac
			local ty = spGetGroundHeight(tx, tz)
			points[#points + 1] = { tx, ty, tz, row = 1, col = i + 1 }
		end
		return points, count, 1
	end

	-- MULTI-ROW PHALANX FORMATION:
	-- The drag is too tight/close to fit all units in one row, wrap into new rows!
	local cols = maxCols
	local rows = ceil(count / cols)
	local rowSpacing = minStep * 0.8660254 -- Optimal hexagonal row height
	local colSpacing = (cols > 1) and (totalDist / (cols - 1)) or minStep

	for i = 0, count - 1 do
		local r = floor(i / cols)
		local c = i % cols

		-- Stagger alternate rows (honeycomb offset) to fill crevices
		local stagger = (r % 2 == 1 and cols > 1) and (colSpacing * 0.5) or 0
		local tx = pStart[1] + ux * (c * colSpacing + stagger) + nx * (r * rowSpacing)
		local tz = pStart[3] + uz * (c * colSpacing + stagger) + nz * (r * rowSpacing)
		local ty = spGetGroundHeight(tx, tz)
		points[#points + 1] = { tx, ty, tz, row = r + 1, col = c + 1 }
	end

	return points, cols, rows
end

-- True 2D Euclidean A2 Hexagonal Close-Packed Lattice Generator
local function GenerateHexagonalTessellation(center, radius, count, avgAoE)
	local points = {}
	if count <= 0 then return points end

	local gy = spGetGroundHeight(center[1], center[3])
	points[1] = { center[1], gy, center[3] }
	if count == 1 then return points end

	-- Optimal packing distance: d = sqrt(3) * AoE * 0.95 gives maximum ground coverage
	local S = max(60, avgAoE * 1.732 * 0.95)
	local halfS = S * 0.5
	local rowH = S * 0.8660254 -- sqrt(3)/2 * S

	local candidates = {}
	local maxRing = max(2, floor(radius / S) + 2)

	for q = -maxRing, maxRing do
		for r = -maxRing, maxRing do
			if q ~= 0 or r ~= 0 then
				local cx = center[1] + (q * S + r * halfS)
				local cz = center[3] + (r * rowH)
				local distSq = (cx - center[1])^2 + (cz - center[3])^2
				candidates[#candidates + 1] = { x = cx, z = cz, distSq = distSq }
			end
		end
	end

	table.sort(candidates, function(a, b) return a.distSq < b.distSq end)

	for i = 1, min(#candidates, count - 1) do
		local c = candidates[i]
		local cy = spGetGroundHeight(c.x, c.z)
		points[#points + 1] = { c.x, cy, c.z }
	end

	return points
end

--------------------------------------------------------------------------------
-- TOPOLOGICAL ZERO-CRISSCROSS MATCHING
--------------------------------------------------------------------------------
local function MatchUnitsToTargetsZeroCrisscross(unitList, targets, dirVector)
	local count = min(#unitList, #targets)
	if count <= 0 then return {} end

	-- Lateral vector perpendicular to firing direction
	local uDirX = -dirVector[2]
	local uDirZ = dirVector[1]

	local decUnits = {}
	for i = 1, #unitList do
		local u = unitList[i]
		local proj = (u.pos[1] * uDirX) + (u.pos[3] * uDirZ)
		decUnits[i] = { unit = u, proj = proj }
	end

	local decTargets = {}
	for j = 1, #targets do
		local t = targets[j]
		local proj = (t[1] * uDirX) + (t[3] * uDirZ)
		decTargets[j] = { target = t, proj = proj }
	end

	table.sort(decUnits, function(a, b) return a.proj < b.proj end)
	table.sort(decTargets, function(a, b) return a.proj < b.proj end)

	local pairings = {}
	for k = 1, count do
		pairings[k] = {
			unit   = decUnits[k].unit,
			target = decTargets[k].target,
		}
	end

	return pairings
end

--------------------------------------------------------------------------------
-- CARPET BARRAGE SOLVER (INTEGRATES DAMAGE TIER, RANGE CHECKS & WEAPON INTEL)
--------------------------------------------------------------------------------
local function BuildCarpetBarragePlan(cmdID, pStart, pEnd, isArea)
	local rawSelected = spGetSelectedUnits()
	if not rawSelected or #rawSelected == 0 then return nil end

	-- 1. Gather combat units and missile silos
	local validUnits = {}
	local totalAoE = 0
	local isSiloBarrage = false
	local isLaunchCommand = (cmdID == CMD_MANUALFIRE or cmdID == 20)

	for i = 1, #rawSelected do
		local uid = rawSelected[i]
		local udefID = spGetUnitDefID(uid)
		if udefID then
			local winfo = GetUnitWeaponInfo(udefID)
			if winfo then
				if winfo.isSilo then
					isSiloBarrage = true
				end

				local ux, uy, uz = spGetUnitPosition(uid)
				local uheading = spGetUnitHeading(uid) or 0
				local readyStock, queuedStock = 0, 0

				if winfo.isSilo then
					local ok, rs, qs = pcall(spGetUnitStockpile, uid)
					if ok then
						readyStock = rs or 0
						queuedStock = qs or 0
					end
				end

				validUnits[#validUnits + 1] = {
					id          = uid,
					pos         = { ux, uy, uz },
					heading     = uheading,
					winfo       = winfo,
					stockReady  = readyStock,
					stockQueued = queuedStock,
				}
				totalAoE = totalAoE + winfo.aoe
			end
		end
	end

	if #validUnits == 0 then return nil end

	-- If Launch command was triggered, filter down to silos exclusively
	if isLaunchCommand or isSiloBarrage then
		local siloOnly = {}
		for i = 1, #validUnits do
			if validUnits[i].winfo.isSilo then
				siloOnly[#siloOnly + 1] = validUnits[i]
			end
		end
		if #siloOnly > 0 then
			validUnits = siloOnly
			isSiloBarrage = true
		end
	end

	local avgAoE = totalAoE / #validUnits

	-- Determine target count:
	local totalPoints = #validUnits
	local singleUnitRepeats = false
	local stockWarning = false

	if #validUnits == 1 then
		local u = validUnits[1]
		if u.winfo.isSilo then
			local totalMissiles = (u.stockReady > 0 and u.stockReady) or (u.stockQueued > 0 and u.stockQueued) or 3
			totalPoints = max(2, min(6, totalMissiles))
			if u.stockReady == 0 then
				stockWarning = true
			end
		else
			totalPoints = 4
		end
		singleUnitRepeats = true
	end

	-- Calculate Battery Center (Centroid of firing units) to orient creeping barrage forward
	local avgBx, avgBy, avgBz = 0, 0, 0
	for i = 1, #validUnits do
		avgBx = avgBx + validUnits[i].pos[1]
		avgBy = avgBy + validUnits[i].pos[2]
		avgBz = avgBz + validUnits[i].pos[3]
	end
	local batteryCenter = { avgBx / #validUnits, avgBy / #validUnits, avgBz / #validUnits }

	-- 2. Tessellation Points
	local targets = {}
	local gridCols = totalPoints
	local gridRows = 1
	local dirX = pEnd[1] - pStart[1]
	local dirZ = pEnd[3] - pStart[3]

	if isArea then
		local rad = max(avgAoE * 1.5, sqrt(dirX * dirX + dirZ * dirZ))
		targets = GenerateHexagonalTessellation(pStart, rad, totalPoints, avgAoE)
	else
		targets, gridCols, gridRows = GenerateLinearTessellation(pStart, pEnd, totalPoints, avgAoE, batteryCenter)
	end

	local dirLen = sqrt(dirX * dirX + dirZ * dirZ)
	if dirLen < 0.001 then
		dirX, dirZ = 1, 0
	else
		dirX, dirZ = dirX / dirLen, dirZ / dirLen
	end

	-- 3. Pair Units with Targets, Solve Physics, Range Checks & Damage
	local salvoElements = {}
	local maxReadyTime = 0
	local currentFrame = spGetGameFrame()
	local totalSalvoDamage = 0
	local highestDamageProfile = nil
	local highestDamage = -1
	local outOfRangeCount = 0
	local minRangeCount = 0
	local maxWeaponRangeFound = 0
	local hasAnyImmobile = false

	if singleUnitRepeats then
		local u = validUnits[1]
		local prof = u.winfo.damageProfile
		highestDamageProfile = prof
		if u.winfo.isImmobile then hasAnyImmobile = true end
		maxWeaponRangeFound = u.winfo.range

		for k = 1, #targets do
			local t = targets[k]
			local dx = t[1] - u.pos[1]
			local dy = t[2] - u.pos[2]
			local dz = t[3] - u.pos[3]
			local horizDist = sqrt(dx * dx + dz * dz)

			-- Dynamic range including Spring elevation advantage (shooter height vs target)
			local elevationBonus = max(0, -dy * 0.25)
			local effectiveMaxRange = (u.winfo.range or 72000) + elevationBonus
			local effectiveMinRange = u.winfo.minRange or 0

			local isOutOfRange = (horizDist > effectiveMaxRange)
			local isMinRange = (effectiveMinRange > 0 and horizDist < effectiveMinRange)

			if isOutOfRange then outOfRangeCount = outOfRangeCount + 1 end
			if isMinRange then minRangeCount = minRangeCount + 1 end

			local flightTime = SolveFlightTime(dx, dy, dz, u.winfo)
			local slewTime = SolveTurretSlewTime(u.pos[1], u.pos[3], u.heading, t[1], t[3], u.winfo.turnRate)
			local seqDelaySec = (k - 1) * u.winfo.reloadTime
			local totalTimeToImpact = seqDelaySec + flightTime

			totalSalvoDamage = totalSalvoDamage + u.winfo.damage

			salvoElements[k] = {
				unitID            = u.id,
				unitPos           = u.pos,
				targetPos         = t,
				aoe               = u.winfo.aoe,
				damage            = u.winfo.damage,
				damageProfile     = prof,
				flightTime        = flightTime,
				slewTime          = slewTime,
				readyTime         = totalTimeToImpact,
				isQueued          = (k > 1),
				seqDelaySec       = seqDelaySec,
				delayFrames       = 0,
				fireFrame         = currentFrame,
				horizDist         = horizDist,
				effectiveMaxRange = effectiveMaxRange,
				effectiveMinRange = effectiveMinRange,
				isOutOfRange      = isOutOfRange,
				isMinRange        = isMinRange,
				rangeViolation    = (isOutOfRange or isMinRange),
				isImmobile        = u.winfo.isImmobile,
				row               = t.row or 1,
				col               = t.col or k,
			}
			maxReadyTime = max(maxReadyTime, totalTimeToImpact)
		end
	else
		local pairings = MatchUnitsToTargetsZeroCrisscross(validUnits, targets, { dirX, dirZ })
		for k = 1, #pairings do
			local p = pairings[k]
			local u = p.unit
			local t = p.target

			if u.winfo.isImmobile then hasAnyImmobile = true end
			if (u.winfo.range or 0) > maxWeaponRangeFound then
				maxWeaponRangeFound = u.winfo.range or 0
			end

			local dx = t[1] - u.pos[1]
			local dy = t[2] - u.pos[2]
			local dz = t[3] - u.pos[3]
			local horizDist = sqrt(dx * dx + dz * dz)

			-- Dynamic range including Spring elevation advantage
			local elevationBonus = max(0, -dy * 0.25)
			local effectiveMaxRange = (u.winfo.range or 72000) + elevationBonus
			local effectiveMinRange = u.winfo.minRange or 0

			local isOutOfRange = (horizDist > effectiveMaxRange)
			local isMinRange = (effectiveMinRange > 0 and horizDist < effectiveMinRange)

			if isOutOfRange then outOfRangeCount = outOfRangeCount + 1 end
			if isMinRange then minRangeCount = minRangeCount + 1 end

			local flightTime = SolveFlightTime(dx, dy, dz, u.winfo)
			local slewTime = SolveTurretSlewTime(u.pos[1], u.pos[3], u.heading, t[1], t[3], u.winfo.turnRate)
			local readyTime = slewTime + flightTime

			if readyTime > maxReadyTime then
				maxReadyTime = readyTime
			end

			totalSalvoDamage = totalSalvoDamage + u.winfo.damage
			if u.winfo.damage > highestDamage then
				highestDamage = u.winfo.damage
				highestDamageProfile = u.winfo.damageProfile
			end

			salvoElements[k] = {
				unitID            = u.id,
				unitPos           = u.pos,
				targetPos         = t,
				aoe               = u.winfo.aoe,
				damage            = u.winfo.damage,
				damageProfile     = u.winfo.damageProfile,
				flightTime        = flightTime,
				slewTime          = slewTime,
				readyTime         = readyTime,
				isQueued          = false,
				horizDist         = horizDist,
				effectiveMaxRange = effectiveMaxRange,
				effectiveMinRange = effectiveMinRange,
				isOutOfRange      = isOutOfRange,
				isMinRange        = isMinRange,
				rangeViolation    = (isOutOfRange or isMinRange),
				isImmobile        = u.winfo.isImmobile,
				row               = t.row or 1,
				col               = t.col or k,
			}
		end

		-- Synchronize Time-On-Target (TOT) fire frames
		for k = 1, #salvoElements do
			local elem = salvoElements[k]
			local fireDelaySec = maxReadyTime - elem.readyTime
			elem.delayFrames = max(0, floor(fireDelaySec * 30))
			elem.fireFrame   = currentFrame + elem.delayFrames
		end
	end

	return {
		commandID            = cmdID,
		elements             = salvoElements,
		maxReadyTime         = maxReadyTime,
		totalUnits           = #salvoElements,
		totalDamage          = totalSalvoDamage,
		dominantProfile      = highestDamageProfile or GetDamageProfile(totalSalvoDamage, false),
		isSilo               = isSiloBarrage,
		isSingleUnit         = singleUnitRepeats,
		stockWarning         = stockWarning,
		pStart               = pStart,
		pEnd                 = pEnd,
		isArea               = isArea,
		gridCols             = gridCols,
		gridRows             = gridRows,
		outOfRangeCount      = outOfRangeCount,
		minRangeCount        = minRangeCount,
		hasRangeViolation    = (outOfRangeCount > 0 or minRangeCount > 0),
		allOutOfRange        = (outOfRangeCount == #salvoElements),
		maxWeaponRange       = maxWeaponRangeFound,
		hasAnyImmobile       = hasAnyImmobile,
	}
end

--------------------------------------------------------------------------------
-- DISPATCHER & TOT SYNCHRONIZED EXECUTION
--------------------------------------------------------------------------------
local function ExecuteCarpetBarrage(plan, shiftHeld)
	if not plan or not plan.elements or #plan.elements == 0 then return end

	local currentFrame = spGetGameFrame()
	local pending = {}

	for i = 1, #plan.elements do
		local elem = plan.elements[i]
		local cmdToIssue = plan.commandID

		local opts = {}
		if shiftHeld or elem.isQueued or (plan.stockWarning and plan.isSilo) then
			opts = { "shift" }
		end

		if elem.fireFrame <= currentFrame or elem.isQueued then
			spGiveOrderToUnit(elem.unitID, cmdToIssue, elem.targetPos, opts)
		else
			pending[#pending + 1] = {
				unitID    = elem.unitID,
				cmdID     = cmdToIssue,
				targetPos = elem.targetPos,
				options   = opts,
				fireFrame = elem.fireFrame,
			}
		end
	end

	if #pending > 0 then
		pendingSalvos[#pendingSalvos + 1] = pending
	end

	pcall(spPlaySoundFile, "beep4", 0.75, "ui")
	if spEcho then
		local salvoType = plan.dominantProfile and plan.dominantProfile.tag or "BARRAGE"
		local warningNote = plan.hasRangeViolation and string.format(" [⚠️ %d OUT OF RANGE]", plan.outOfRangeCount) or ""
		spEcho(string.format("[Carpet Barrage] %s Salvo Deployed: %d warheads | Total Yield: %s DMG%s!",
			salvoType, #plan.elements, FormatNumberCommas(plan.totalDamage), warningNote))
	end
end

function widget:GameFrame(frame)
	if #pendingSalvos == 0 then return end

	local i = 1
	while i <= #pendingSalvos do
		local salvo = pendingSalvos[i]
		local allDispatched = true

		for k = 1, #salvo do
			local item = salvo[k]
			if item and not item.dispatched then
				if frame >= item.fireFrame then
					spGiveOrderToUnit(item.unitID, item.cmdID, item.targetPos, item.options or {})
					item.dispatched = true
				else
					allDispatched = false
				end
			end
		end

		if allDispatched then
			table.remove(pendingSalvos, i)
		else
			i = i + 1
		end
	end
end

--------------------------------------------------------------------------------
-- MOUSE & IN-GAME ORDER CAPTURE
--------------------------------------------------------------------------------
function widget:MousePress(mx, my, button)
	if spIsGUIHidden and spIsGUIHidden() then return false end

	-- Right-Click Cancel while holding Left-Click drag (กดซ้ายค้าง ถ้าคลิกขวายกเลิก)
	if isDragging and button == 3 then
		isDragging = false
		dragStartWorld = nil
		dragCurrentWorld = nil
		activeBarragePreview = nil
		hasDraggedPastThreshold = false
		dragTargetUnitID = nil
		hadRangeViolationLast = false
		pcall(spPlaySoundFile, "beep4", 0.40, "ui")
		spSetActiveCommand(0)
		return true
	end

	local alt, ctrl, meta, shift = spGetModKeyState()

	-- 1. Alt + Right-Click Drag Shortcut
	if button == 3 and alt then
		local sel = spGetSelectedUnits()
		if sel and #sel >= 1 then
			local gpos, tid = GetGroundPosFromMouse(mx, my)
			if gpos then
				isDragging = true
				hasDraggedPastThreshold = false
				hadRangeViolationLast = false
				dragStartScreen.x = mx
				dragStartScreen.y = my
				dragCommandID = CMD_ATTACK
				dragStartWorld = gpos
				dragCurrentWorld = gpos
				dragTargetUnitID = tid
				dragShiftHeld = shift
				isAreaMode = ctrl
				activeBarragePreview = nil
				return true
			end
		end
	end

	-- 2. Intercepting Active In-Game Buttons (Launch, Attack, Set Target)
	if button == 1 then
		local cmdIndex, activeCmdID, _, activeCmdName = spGetActiveCommand()
		if IsCarpetCapableCommand(activeCmdID, activeCmdName, cmdIndex) then
			local sel = spGetSelectedUnits()
			if sel and #sel >= 1 then
				local gpos, tid = GetGroundPosFromMouse(mx, my)
				if gpos then
					isDragging = true
					hasDraggedPastThreshold = false
					hadRangeViolationLast = false
					dragStartScreen.x = mx
					dragStartScreen.y = my
					dragCommandID = (activeCmdID and activeCmdID > 0) and activeCmdID or CMD_ATTACK
					dragStartWorld = gpos
					dragCurrentWorld = gpos
					dragTargetUnitID = tid
					dragShiftHeld = shift
					isAreaMode = ctrl
					activeBarragePreview = nil
					return true
				end
			end
		end
	end

	return false
end

function widget:MouseMove(mx, my, dx, dy, button)
	if not isDragging or not dragStartWorld then return false end

	local gpos = GetGroundPosFromMouse(mx, my)
	if gpos then
		dragCurrentWorld = gpos
		local _, ctrl, _, shift = spGetModKeyState()
		isAreaMode = ctrl
		dragShiftHeld = shift

		local sDist = sqrt((mx - dragStartScreen.x)^2 + (my - dragStartScreen.y)^2)
		if sDist >= DRAG_PIXEL_THRESHOLD then
			hasDraggedPastThreshold = true
			activeBarragePreview = BuildCarpetBarragePlan(dragCommandID, dragStartWorld, dragCurrentWorld, isAreaMode)

			-- Audio warning feedback on first out-of-range breach
			if activeBarragePreview and activeBarragePreview.hasRangeViolation then
				if not hadRangeViolationLast then
					hadRangeViolationLast = true
					pcall(spPlaySoundFile, "beep4", 0.45, "ui")
				end
			else
				hadRangeViolationLast = false
			end
		else
			activeBarragePreview = nil
			hadRangeViolationLast = false
		end
	end

	return true
end

function widget:MouseRelease(mx, my, button)
	if not isDragging then return false end

	local _, _, _, shift = spGetModKeyState()
	dragShiftHeld = shift or dragShiftHeld

	if hasDraggedPastThreshold and activeBarragePreview and activeBarragePreview.totalUnits >= 1 then
		ExecuteCarpetBarrage(activeBarragePreview, dragShiftHeld)
		spSetActiveCommand(0)
	else
		-- Single-Click Passthrough: preserve 100% native Launch / Attack behavior
		local sel = spGetSelectedUnits()
		if sel and #sel > 0 then
			local options = dragShiftHeld and { "shift" } or {}
			local targetParams = nil
			if dragTargetUnitID then
				targetParams = { dragTargetUnitID }
			elseif dragStartWorld then
				targetParams = { dragStartWorld[1], dragStartWorld[2], dragStartWorld[3] }
			end

			if targetParams then
				for i = 1, #sel do
					spGiveOrderToUnit(sel[i], dragCommandID, targetParams, options)
				end
			end
		end
		if not dragShiftHeld then
			spSetActiveCommand(0)
		end
	end

	isDragging = false
	dragStartWorld = nil
	dragCurrentWorld = nil
	activeBarragePreview = nil
	hasDraggedPastThreshold = false
	dragTargetUnitID = nil
	hadRangeViolationLast = false

	return true
end

--------------------------------------------------------------------------------
-- ZERO-GC DAMAGE-TIER HOLOGRAPHIC WORLD RENDERING WITH RANGE ALERTS
--------------------------------------------------------------------------------
local function DrawGroundRingZeroGC(cx, cy, cz, radius, r, g, b, a, isNuclear, isOutOfRange)
	-- Subtle translucent damage-tinted or alert fill
	glColor(r, g, b, a * (isOutOfRange and 0.28 or 0.18))
	glBeginEnd(GL_TRIANGLE_FAN, function()
		glVertex(cx, cy + 4, cz)
		for i = 0, CIRCLE_SEGMENTS do
			local px = cx + CIRCLE_COS[i] * radius
			local pz = cz + CIRCLE_SIN[i] * radius
			glVertex(px, cy + 4, pz)
		end
	end)

	-- High-contrast outer perimeter ring
	glColor(r, g, b, a)
	glLineWidth(isOutOfRange and 3.0 or 2.6)
	glBeginEnd(GL_LINE_LOOP, function()
		for i = 0, CIRCLE_SEGMENTS - 1 do
			local px = cx + CIRCLE_COS[i] * radius
			local pz = cz + CIRCLE_SIN[i] * radius
			glVertex(px, cy + 6, pz)
		end
	end)

	-- Concentric Shockwave Pulse for Nuclear / Apocalyptic Tier (>= 5,000 DMG)
	if isNuclear and not isOutOfRange then
		glColor(r, g, b, a * 0.70)
		glLineWidth(1.8)
		glBeginEnd(GL_LINE_LOOP, function()
			local innerR = radius * 0.62
			for i = 0, CIRCLE_SEGMENTS - 1 do
				local px = cx + CIRCLE_COS[i] * innerR
				local pz = cz + CIRCLE_SIN[i] * innerR
				glVertex(px, cy + 5, pz)
			end
		end)
	end
end

local function DrawBallisticLaserArc(pStart, pEnd, r, g, b, a, isSilo, isOutOfRange)
	local segments = 28
	local dx = pEnd[1] - pStart[1]
	local dy = pEnd[2] - pStart[2]
	local dz = pEnd[3] - pStart[3]
	local dist = sqrt(dx * dx + dz * dz)
	local arcHeight = isSilo and max(250, dist * 0.45) or max(80, dist * 0.26)

	glLineWidth(isOutOfRange and 2.8 or 2.4)
	glBeginEnd(GL_LINE_STRIP, function()
		for i = 0, segments do
			local t = i / segments
			local px = pStart[1] + dx * t
			local pz = pStart[3] + dz * t
			local py = pStart[2] + dy * t + sin(t * pi) * arcHeight
			local alpha = a * (0.30 + sin(t * pi) * 0.70)
			if isOutOfRange and (i % 2 == 1) then
				-- Dashed warning arc for out of range
				alpha = alpha * 0.20
			end
			glColor(r, g, b, alpha)
			glVertex(px, py, pz)
		end
	end)
end

function widget:DrawWorld()
	if not activeBarragePreview or not activeBarragePreview.elements then return end

	local gameSecs = spGetGameSeconds()
	local normalPulse = 0.82 + 0.18 * sin(gameSecs * 6.5)
	local alertStrobe = 0.55 + 0.45 * sin(gameSecs * 14.0)

	glDepthTest(false)

	local elems = activeBarragePreview.elements
	local isSilo = activeBarragePreview.isSilo
	local isWarn = activeBarragePreview.stockWarning
	local domProf = activeBarragePreview.dominantProfile

	for i = 1, #elems do
		local elem = elems[i]
		local tp = elem.targetPos
		local up = elem.unitPos
		local prof = elem.damageProfile or domProf
		local isOut = elem.isOutOfRange
		local isMin = elem.isMinRange

		-- Determine Reticle Color: Out of range (Crimson Red) > Min range (Amber-Orange) > Stockpile Warn > Damage Tier
		local ringR, ringG, ringB, ringPulse
		if isOut then
			ringR = 1.00
			ringG = 0.10 * alertStrobe
			ringB = 0.15 * alertStrobe
			ringPulse = alertStrobe
		elseif isMin then
			ringR = 1.00
			ringG = 0.45 * alertStrobe
			ringB = 0.05
			ringPulse = alertStrobe
		elseif isWarn then
			ringR = 1.00
			ringG = 0.55
			ringB = 0.10
			ringPulse = normalPulse
		else
			ringR = prof.r
			ringG = prof.g
			ringB = prof.b
			ringPulse = normalPulse
		end

		local isNuke = (prof.tier == 4)

		-- Ground Impact Blast Reticle
		DrawGroundRingZeroGC(tp[1], tp[2], tp[3], elem.aoe, ringR, ringG, ringB, 0.88 * ringPulse, isNuke, isOut or isMin)

		-- Reticle Crosshairs or Forbidden "X"
		local chSize = elem.aoe * 0.42
		glColor(ringR, ringG, ringB, 0.90 * ringPulse)

		if isOut or isMin then
			-- Heavy "X" Forbidden Mark for Range Violations
			glLineWidth(2.5)
			glBeginEnd(GL_LINES, function()
				glVertex(tp[1] - chSize, tp[2] + 7, tp[3] - chSize)
				glVertex(tp[1] + chSize, tp[2] + 7, tp[3] + chSize)
				glVertex(tp[1] - chSize, tp[2] + 7, tp[3] + chSize)
				glVertex(tp[1] + chSize, tp[2] + 7, tp[3] - chSize)
			end)
		else
			-- Standard Precision Crosshairs
			glLineWidth(2.0)
			glBeginEnd(GL_LINES, function()
				glVertex(tp[1] - chSize, tp[2] + 6, tp[3])
				glVertex(tp[1] + chSize, tp[2] + 6, tp[3])
				glVertex(tp[1], tp[2] + 6, tp[3] - chSize)
				glVertex(tp[1], tp[2] + 6, tp[3] + chSize)
			end)
		end

		-- Trajectory Flight Arc (with range alert styling)
		DrawBallisticLaserArc(up, tp, ringR, ringG, ringB, 0.80, isSilo, isOut or isMin)
	end

	-- Interconnecting tactical salvo line colored by dominant damage tier or alert
	if #elems >= 2 then
		local hasAlert = activeBarragePreview.hasRangeViolation
		local lineR = hasAlert and 1.00 or (isWarn and 1.00 or domProf.r)
		local lineG = hasAlert and (0.15 * alertStrobe) or (isWarn and 0.55 or domProf.g)
		local lineB = hasAlert and (0.18 * alertStrobe) or (isWarn and 0.10 or domProf.b)

		glColor(lineR, lineG, lineB, 0.70)
		glLineWidth(2.2)

		local gridRows = activeBarragePreview.gridRows or 1
		if gridRows > 1 then
			-- Draw individual line along each row
			for r = 1, gridRows do
				glBeginEnd(GL_LINE_STRIP, function()
					for i = 1, #elems do
						local elem = elems[i]
						if (elem.row or 1) == r then
							local tp = elem.targetPos
							glVertex(tp[1], tp[2] + 8, tp[3])
						end
					end
				end)
			end
			-- Connect columns between adjacent rows
			glLineWidth(1.6)
			glColor(lineR, lineG, lineB, 0.35)
			glBeginEnd(GL_LINES, function()
				for i = 1, #elems do
					local elemA = elems[i]
					for j = 1, #elems do
						local elemB = elems[j]
						if (elemB.row or 1) == (elemA.row or 1) + 1 and abs((elemB.col or 0) - (elemA.col or 0)) <= 1 then
							glVertex(elemA.targetPos[1], elemA.targetPos[2] + 8, elemA.targetPos[3])
							glVertex(elemB.targetPos[1], elemB.targetPos[2] + 8, elemB.targetPos[3])
						end
					end
				end
			end)
		else
			glBeginEnd(GL_LINE_STRIP, function()
				for i = 1, #elems do
					local tp = elems[i].targetPos
					glVertex(tp[1], tp[2] + 8, tp[3])
				end
			end)
		end
	end

	glDepthTest(true)
	glColor(1, 1, 1, 1)
	glLineWidth(1.0)
end

--------------------------------------------------------------------------------
-- 2D SCREEN HUD & 3D WORLD TELEMETRY WITH RANGE WARNINGS
--------------------------------------------------------------------------------
function widget:DrawScreen()
	if not activeBarragePreview or not activeBarragePreview.elements then return end

	local gameSecs = spGetGameSeconds()
	local alertPulse = 0.55 + 0.45 * sin(gameSecs * 14.0)

	local vsx, vsy = spGetViewGeometry()
	local elems = activeBarragePreview.elements
	local isSilo = activeBarragePreview.isSilo
	local isWarn = activeBarragePreview.stockWarning
	local domProf = activeBarragePreview.dominantProfile
	local hasRangeAlert = activeBarragePreview.hasRangeViolation

	-- 1. Draw 3D-Projected Countdown, Range Alerts & Damage Labels Above Each Target Reticle
	for i = 1, #elems do
		local elem = elems[i]
		local prof = elem.damageProfile or domProf
		local isOut = elem.isOutOfRange
		local isMin = elem.isMinRange
		local sx, sy = spWorldToScreenCoords(elem.targetPos[1], elem.targetPos[2] + 20, elem.targetPos[3])

		if sx and sy and sx > 0 and sy > 0 and sx < vsx and sy < vsy then
			if isOut then
				-- Out-of-Range Emergency Alert Label
				local overDist = floor(elem.horizDist - elem.effectiveMaxRange)
				local alertStr = "⚠️ [ OUT OF RANGE ]"
				local rangeDetail = string.format("%dm (MAX %dm  +%dm)", floor(elem.horizDist), floor(elem.effectiveMaxRange), overDist)
				local dmgStr = string.format("[%s %s]", FormatNumberCommas(elem.damage), prof.isEMP and "EMP" or "DMG")

				-- Shadow
				glColor(0.0, 0.0, 0.0, 0.95)
				glText(alertStr, sx + 1, sy + 21, 11, "cn")
				glText(rangeDetail, sx + 1, sy + 7, 10, "cn")
				glText(dmgStr, sx + 1, sy - 7, 9, "cn")

				-- Flashing Crimson Warning
				glColor(1.00, 0.15 * alertPulse, 0.20 * alertPulse, 1.0)
				glText(alertStr, sx, sy + 22, 11, "cn")

				glColor(1.00, 0.70, 0.70, 0.95)
				glText(rangeDetail, sx, sy + 8, 10, "cn")

				glColor(prof.r * 0.75, prof.g * 0.75, prof.b * 0.75, 0.80)
				glText(dmgStr, sx, sy - 6, 9, "cn")

			elseif isMin then
				-- Minimum-Range Caution Label
				local underDist = floor(elem.effectiveMinRange - elem.horizDist)
				local alertStr = "⚠️ [ TOO CLOSE (MIN RANGE) ]"
				local rangeDetail = string.format("%dm (MIN %dm  -%dm)", floor(elem.horizDist), floor(elem.effectiveMinRange), underDist)
				local dmgStr = string.format("[%s %s]", FormatNumberCommas(elem.damage), prof.isEMP and "EMP" or "DMG")

				glColor(0.0, 0.0, 0.0, 0.95)
				glText(alertStr, sx + 1, sy + 21, 11, "cn")
				glText(rangeDetail, sx + 1, sy + 7, 10, "cn")
				glText(dmgStr, sx + 1, sy - 7, 9, "cn")

				glColor(1.00, 0.50 * alertPulse, 0.10, 1.0)
				glText(alertStr, sx, sy + 22, 11, "cn")

				glColor(1.00, 0.80, 0.60, 0.95)
				glText(rangeDetail, sx, sy + 8, 10, "cn")

				glColor(prof.r * 0.75, prof.g * 0.75, prof.b * 0.75, 0.80)
				glText(dmgStr, sx, sy - 6, 9, "cn")

			else
				-- Standard Clean In-Range Telemetry Label
				local timerStr = string.format("T-%04.1fs", elem.readyTime)
				local distStr = string.format("%dm / %dm", floor(elem.horizDist), floor(elem.effectiveMaxRange))
				local dmgStr = prof.isEMP and string.format("[%s EMP]", FormatNumberCommas(elem.damage))
					or string.format("[%s DMG]", FormatNumberCommas(elem.damage))

				glColor(0.0, 0.0, 0.0, 0.90)
				glText(timerStr, sx + 1, sy + 21, 11, "cn")
				glText(distStr, sx + 1, sy + 7, 9, "cn")
				glText(dmgStr, sx + 1, sy - 7, 10, "cn")

				if isWarn then
					glColor(1.0, 0.60, 0.10, 1.0)
				else
					glColor(0.95, 0.95, 0.95, 1.0)
				end
				glText(timerStr, sx, sy + 22, 11, "cn")

				glColor(0.70, 0.85, 0.95, 0.85)
				glText(distStr, sx, sy + 8, 9, "cn")

				glColor(prof.r, prof.g, prof.b, 1.0)
				glText(dmgStr, sx, sy - 6, 10, "cn")
			end
		end
	end

	-- 2. Glassmorphic Military HUD
	local hudW = 460
	local hudH = 96
	local hudX = (vsx - hudW) * 0.5
	local hudY = vsy - 135

	local borderR, borderG, borderB
	if hasRangeAlert then
		borderR = 1.00
		borderG = 0.18 * alertPulse
		borderB = 0.20 * alertPulse
	elseif isWarn then
		borderR = 1.00
		borderG = 0.55
		borderB = 0.10
	else
		borderR = domProf.r
		borderG = domProf.g
		borderB = domProf.b
	end

	-- Backdrop Glass
	glColor(0.012, 0.032, 0.070, 0.92)
	glRect(hudX, hudY, hudX + hudW, hudY + hudH)

	-- Glowing Tech Border tinted by range alert or dominant damage tier
	glColor(borderR, borderG, borderB, 0.95)
	glLineWidth(hasRangeAlert and 2.6 or 2.2)
	glBeginEnd(GL_LINE_LOOP, function()
		glVertex(hudX, hudY)
		glVertex(hudX + hudW, hudY)
		glVertex(hudX + hudW, hudY + hudH)
		glVertex(hudX, hudY + hudH)
	end)

	-- Header Title + Alert / Damage Tier Badge
	local baseType = ""
	if isSilo then
		baseType = isWarn and "ICBM SILO (QUEUED)" or "ICBM NUCLEAR SALVO"
	elseif activeBarragePreview.isArea then
		baseType = "HEX BARRAGE (TOT)"
	elseif activeBarragePreview.gridRows and activeBarragePreview.gridRows > 1 then
		baseType = string.format("MULTI-ROW PHALANX (%d×%d GRID)", activeBarragePreview.gridCols, activeBarragePreview.gridRows)
	else
		baseType = "LINEAR CARPET (TOT)"
	end

	local headerText = ""
	if activeBarragePreview.allOutOfRange then
		headerText = string.format("%s  •  [ ⚠️ ALL TARGETS OUT OF RANGE ]", baseType)
	elseif hasRangeAlert then
		headerText = string.format("%s  •  [ ⚠️ OUT OF RANGE: %d/%d UNITS ]", baseType, activeBarragePreview.outOfRangeCount, activeBarragePreview.totalUnits)
	else
		headerText = string.format("%s  •  [%s]", baseType, domProf.tag)
	end

	glColor(borderR, borderG, borderB, 1.0)
	glText(headerText, hudX + 16, hudY + 66, 12, "o")

	-- Detailed Salvo Telemetry
	local telemetryStr = ""
	local dmgFormatted = FormatNumberCommas(activeBarragePreview.totalDamage)
	local dmgUnit = domProf.isEMP and "EMP" or "DMG"

	if hasRangeAlert then
		telemetryStr = string.format("SALVO: %d UNITS  |  TOTAL: %s %s  |  ⚠️ %d OUT OF RANGE (MAX %dm)",
			activeBarragePreview.totalUnits, dmgFormatted, dmgUnit, activeBarragePreview.outOfRangeCount, floor(activeBarragePreview.maxWeaponRange or 0))
	elseif isSilo and activeBarragePreview.isSingleUnit then
		telemetryStr = string.format("SALVO: %d WARHEADS  |  TOTAL: %s %s  |  SEQ: %.1fs -> %.1fs",
			activeBarragePreview.totalUnits, dmgFormatted, dmgUnit, elems[1].readyTime, activeBarragePreview.maxReadyTime)
	else
		telemetryStr = string.format("SALVO: %d WARHEADS  |  TOTAL: %s %s  |  IMPACT: %.1fs",
			activeBarragePreview.totalUnits, dmgFormatted, dmgUnit, activeBarragePreview.maxReadyTime)
	end
	glColor(0.90, 0.95, 1.0, 0.95)
	glText(telemetryStr, hudX + 16, hudY + 42, 11, "o")

	-- Damage Intensity Visual Meter Bar
	local meterX = hudX + 16
	local meterY = hudY + 24
	local meterW = 200
	local meterH = 6
	local fillFrac = min(1.0, activeBarragePreview.totalDamage / 40000)

	glColor(0.10, 0.15, 0.22, 0.85)
	glRect(meterX, meterY, meterX + meterW, meterY + meterH)

	glColor(borderR, borderG, borderB, 0.95)
	glRect(meterX, meterY, meterX + (meterW * fillFrac), meterY + meterH)

	local tierNote = hasRangeAlert and "⚠️ RANGE VIOLATION DETECTED" or string.format("INTENSITY: %s", domProf.tierName)
	glColor(hasRangeAlert and 1.0 or 0.65, hasRangeAlert and 0.4 or 0.82, hasRangeAlert and 0.4 or 0.95, 0.85)
	glText(tierNote, meterX + meterW + 12, meterY - 1, 9, "o")

	-- Action Hint Line
	local hintText = ""
	if hasRangeAlert then
		if activeBarragePreview.hasAnyImmobile then
			hintText = "⚠️ OUT OF RANGE • Right-Click / Esc to Cancel • Drag Closer"
		else
			hintText = "⚠️ OUT OF RANGE: Units will advance to range • Right-Click / Esc to Cancel"
		end
	elseif isWarn then
		hintText = "Missiles will launch automatically upon construction • Right-Click / Esc to Cancel"
	else
		hintText = "Release to Fire  |  Right-Click / Esc to Cancel  |  Ctrl for Hex  |  Shift to Queue"
	end

	glColor(hasRangeAlert and 1.00 or 0.60, hasRangeAlert and 0.50 or 0.78, hasRangeAlert and 0.50 or 0.90, 0.85)
	glText(hintText, hudX + 16, hudY + 8, 9, "o")

	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- KEYBOARD INPUT HANDLER (ESC CANCELS DRAG)
--------------------------------------------------------------------------------
function widget:KeyPress(key, mods, isRepeat)
	-- Escape key (27) cancels active drag session immediately
	if (key == 27 or key == 0x01B) and isDragging then
		isDragging = false
		dragStartWorld = nil
		dragCurrentWorld = nil
		activeBarragePreview = nil
		hasDraggedPastThreshold = false
		dragTargetUnitID = nil
		hadRangeViolationLast = false
		pcall(spPlaySoundFile, "beep4", 0.40, "ui")
		spSetActiveCommand(0)
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- SHUTDOWN CLEANUP
--------------------------------------------------------------------------------
function widget:Shutdown()
	pendingSalvos = {}
	activeBarragePreview = nil
	unitWeaponCache = {}
	isDragging = false
	hadRangeViolationLast = false
end
