local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Tactical Carpet Barrage & TOT",
		desc = "Synchronized Time-On-Target (TOT) non-overlapping carpet bombardment for artillery, rockets, and missile silos.",
		author = "reforged25-source / Codex",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = true,
		handler = true,
	}
end

--------------------------------------------------------------------------------
-- SPRING API SPEEDUPS
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
local pi                       = math.pi
local TWO_PI                   = math.pi * 2
local DEG_TO_RAD               = math.pi / 180
local SPRING_HEADING_SCALE     = (2 * math.pi) / 65536

--------------------------------------------------------------------------------
-- COMMAND CONSTANTS
--------------------------------------------------------------------------------
local CMD_ATTACK               = CMD.ATTACK or 16
local CMD_SET_TARGET           = (CMD and CMD.SET_TARGET) or 34923
local CMD_MANUALFIRE           = (CMD and CMD.MANUALFIRE) or 20
local CMD_STOCKPILE            = (CMD and CMD.STOCKPILE) or 100

local DRAG_PIXEL_THRESHOLD     = 8 -- Screen pixels before engaging carpet barrage
local GRAVITY_CONSTANT         = 130.0

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

local activeBarragePreview     = nil
local pendingSalvos            = {}
local unitWeaponCache          = {}

--------------------------------------------------------------------------------
-- DYNAMIC COMMAND RESOLVER (ATTACK, SET TARGET, LAUNCH)
--------------------------------------------------------------------------------
local function GetUnitCommandIDByName(unitID, keyword)
	local ok, cmdDescs = pcall(spGetUnitCmdDescs, unitID)
	if ok and cmdDescs then
		local kw = string.lower(keyword)
		for i = 1, #cmdDescs do
			local d = cmdDescs[i]
			if d and d.name and string.lower(d.name):find(kw) then
				return d.id
			end
			if d and d.action and string.lower(d.action):find(kw) then
				return d.id
			end
		end
	end
	return nil
end

local function IsCarpetCommand(cmdID, cmdName, cmdIndex)
	if cmdID and (cmdID == CMD_ATTACK or cmdID == 16 or cmdID == CMD_SET_TARGET or cmdID == 34923 or cmdID == CMD_MANUALFIRE or cmdID == 20) then
		return true
	end

	-- Safely check command descriptor using cmdIndex
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
-- WEAPON & BALLISTICS ENGINE (ARTILLERY, ROCKETS, SILOS, NUKES)
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

	-- 1. Check if unit is a Missile Silo (Nuke Silo / Tactical Missile / Juno)
	if udef.canStockpile then
		local bestWeapon = nil
		if udef.weapons and #udef.weapons > 0 then
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

		local aoeRadius = (bestWeapon and bestWeapon.damageAreaOfEffect) or 400
		local info = {
			name         = (bestWeapon and bestWeapon.name) or "Silo Missile",
			range        = (bestWeapon and bestWeapon.range) or 72000,
			minRange     = (bestWeapon and bestWeapon.minRange) or 0,
			aoe          = max(80, aoeRadius),
			projSpeed    = max(150, (bestWeapon and bestWeapon.projectilespeed) or 300),
			isBallistic  = false,
			highTraj     = true,
			turnRate     = 1.0,
			isSilo       = true,
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

	local info = {
		name         = bestWeapon.name or "Cannon",
		range        = bestWeapon.range or 600,
		minRange     = bestWeapon.minRange or 0,
		aoe          = max(24, bestWeapon.damageAreaOfEffect or 32),
		projSpeed    = max(100, bestWeapon.projectilespeed or 350),
		isBallistic  = (bestWeapon.type == "Cannon" or bestWeapon.type == "MissileLauncher"),
		highTraj     = bestWeapon.trajectoryHeight and (bestWeapon.trajectoryHeight > 0),
		turnRate     = max(0.2, (udef.turnRate or 300) * DEG_TO_RAD),
		isSilo       = false,
	}

	unitWeaponCache[unitDefID] = info
	return info
end

local function SolveFlightTime(dx, dy, dz, projSpeed, isBallistic, highTraj)
	local horizDist = sqrt(dx * dx + dz * dz)
	if horizDist <= 1 then return 0.1 end

	if not isBallistic then
		local totalDist = sqrt(horizDist * horizDist + dy * dy)
		return max(0.1, totalDist / projSpeed)
	end

	local g = GRAVITY_CONSTANT
	local v = projSpeed
	local v2 = v * v
	local v4 = v2 * v2

	local discriminant = v4 - g * (g * horizDist * horizDist + 2 * dy * v2)
	if discriminant < 0 then
		local totalDist = sqrt(horizDist * horizDist + dy * dy)
		return max(0.1, totalDist / v)
	end

	local sqrtDisc = sqrt(discriminant)
	local root = highTraj and (v2 + sqrtDisc) or (v2 - sqrtDisc)
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
-- SPATIAL TESSELLATION & PACKING (HEXAGONAL & LINEAR)
--------------------------------------------------------------------------------
local function GenerateLinearTessellation(pStart, pEnd, count)
	local points = {}
	if count <= 0 then return points end

	local dx = pEnd[1] - pStart[1]
	local dz = pEnd[3] - pStart[3]
	local totalDist = sqrt(dx * dx + dz * dz)

	if count == 1 or totalDist < 1 then
		local gy = spGetGroundHeight(pStart[1], pStart[3])
		points[1] = { pStart[1], gy, pStart[3] }
		return points
	end

	local stepFrac = 1.0 / (count - 1)
	for i = 0, count - 1 do
		local frac = i * stepFrac
		local tx = pStart[1] + dx * frac
		local tz = pStart[3] + dz * frac
		local ty = spGetGroundHeight(tx, tz)
		points[#points + 1] = { tx, ty, tz }
	end

	return points
end

local function GenerateHexagonalTessellation(center, radius, count, avgAoE)
	local points = {}
	if count <= 0 then return points end

	local gy = spGetGroundHeight(center[1], center[3])
	points[1] = { center[1], gy, center[3] }
	if count == 1 then return points end

	local spacing = max(avgAoE * 1.5, 60)
	local ring = 1

	while #points < count do
		local ringRadius = ring * spacing
		local numInRing = ring * 6
		local angleStep = TWO_PI / numInRing

		for i = 0, numInRing - 1 do
			if #points >= count then break end
			local a = i * angleStep
			local tx = center[1] + cos(a) * ringRadius
			local tz = center[3] + sin(a) * ringRadius
			local ty = spGetGroundHeight(tx, tz)
			points[#points + 1] = { tx, ty, tz }
		end
		ring = ring + 1
		if ring > 15 then break end
	end

	return points
end

--------------------------------------------------------------------------------
-- TOPOLOGICAL ZERO-CRISSCROSS MATCHING
--------------------------------------------------------------------------------
local function MatchUnitsToTargetsZeroCrisscross(unitList, targets, dirVector)
	local count = min(#unitList, #targets)
	if count <= 0 then return {} end

	local uDirX = dirVector[1]
	local uDirZ = dirVector[2]

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
-- CARPET BARRAGE SOLVER (COVERS MULTI-UNIT & SINGLE-SILO SALVOS)
--------------------------------------------------------------------------------
local function BuildCarpetBarragePlan(cmdID, pStart, pEnd, isArea)
	local rawSelected = spGetSelectedUnits()
	if not rawSelected or #rawSelected == 0 then return nil end

	-- 1. Gather valid combat units / silos
	local validUnits = {}
	local totalAoE = 0
	local isSiloBarrage = false

	for i = 1, #rawSelected do
		local uid = rawSelected[i]
		local udefID = spGetUnitDefID(uid)
		if udefID then
			local winfo = GetUnitWeaponInfo(udefID)
			if winfo then
				local ux, uy, uz = spGetUnitPosition(uid)
				local uheading = spGetUnitHeading(uid) or 0

				local readyStock, queuedStock = 0, 0
				if winfo.isSilo then
					isSiloBarrage = true
					local ok, rs, qs = pcall(spGetUnitStockpile, uid)
					if ok then
						readyStock, queuedStock = rs or 0, qs or 0
					end
				end

				validUnits[#validUnits + 1] = {
					id          = uid,
					pos         = { ux, uy, uz },
					heading     = uheading,
					winfo       = winfo,
					stockReady  = readyStock or 0,
					stockQueued = queuedStock or 0,
				}
				totalAoE = totalAoE + winfo.aoe
			end
		end
	end

	if #validUnits == 0 then return nil end
	local avgAoE = totalAoE / #validUnits

	-- Determine points to generate:
	local totalPoints = #validUnits
	local singleUnitRepeats = false

	if #validUnits == 1 then
		local u = validUnits[1]
		if u.winfo.isSilo then
			local totalMissiles = (u.stockReady > 0 and u.stockReady) or (u.stockQueued > 0 and u.stockQueued) or 3
			totalPoints = max(2, min(6, totalMissiles))
		else
			totalPoints = 4
		end
		singleUnitRepeats = true
	end

	-- 2. Tessellation Points
	local targets = {}
	local dirX = pEnd[1] - pStart[1]
	local dirZ = pEnd[3] - pStart[3]

	if isArea then
		local rad = max(avgAoE * 1.5, sqrt(dirX * dirX + dirZ * dirZ))
		targets = GenerateHexagonalTessellation(pStart, rad, totalPoints, avgAoE)
	else
		targets = GenerateLinearTessellation(pStart, pEnd, totalPoints)
	end

	local dirLen = sqrt(dirX * dirX + dirZ * dirZ)
	if dirLen < 0.001 then
		dirX, dirZ = 1, 0
	else
		dirX, dirZ = dirX / dirLen, dirZ / dirLen
	end

	-- 3. Pair Units with Targets
	local salvoElements = {}
	local maxReadyTime = 0

	if singleUnitRepeats then
		local u = validUnits[1]
		for k = 1, #targets do
			local t = targets[k]
			local dx = t[1] - u.pos[1]
			local dy = t[2] - u.pos[2]
			local dz = t[3] - u.pos[3]

			local flightTime = SolveFlightTime(dx, dy, dz, u.winfo.projSpeed, u.winfo.isBallistic, u.winfo.highTraj)
			local slewTime = SolveTurretSlewTime(u.pos[1], u.pos[3], u.heading, t[1], t[3], u.winfo.turnRate)

			salvoElements[k] = {
				unitID     = u.id,
				unitPos    = u.pos,
				targetPos  = t,
				aoe        = u.winfo.aoe,
				flightTime = flightTime,
				slewTime   = slewTime,
				readyTime  = slewTime + flightTime,
				isQueued   = (k > 1),
			}
			maxReadyTime = max(maxReadyTime, slewTime + flightTime)
		end
	else
		local pairings = MatchUnitsToTargetsZeroCrisscross(validUnits, targets, { dirX, dirZ })
		for k = 1, #pairings do
			local p = pairings[k]
			local u = p.unit
			local t = p.target

			local dx = t[1] - u.pos[1]
			local dy = t[2] - u.pos[2]
			local dz = t[3] - u.pos[3]

			local flightTime = SolveFlightTime(dx, dy, dz, u.winfo.projSpeed, u.winfo.isBallistic, u.winfo.highTraj)
			local slewTime = SolveTurretSlewTime(u.pos[1], u.pos[3], u.heading, t[1], t[3], u.winfo.turnRate)
			local readyTime = slewTime + flightTime

			if readyTime > maxReadyTime then
				maxReadyTime = readyTime
			end

			salvoElements[k] = {
				unitID     = u.id,
				unitPos    = u.pos,
				targetPos  = t,
				aoe        = u.winfo.aoe,
				flightTime = flightTime,
				slewTime   = slewTime,
				readyTime  = readyTime,
				isQueued   = false,
			}
		end
	end

	-- 4. Calculate Frame Delays for TOT Synchronization
	local currentFrame = spGetGameFrame()
	for k = 1, #salvoElements do
		local elem = salvoElements[k]
		if singleUnitRepeats then
			elem.delayFrames = 0
			elem.fireFrame = currentFrame
		else
			local fireDelaySec = maxReadyTime - elem.readyTime
			elem.delayFrames = max(0, floor(fireDelaySec * 30))
			elem.fireFrame   = currentFrame + elem.delayFrames
		end
	end

	return {
		commandID      = cmdID,
		elements       = salvoElements,
		maxReadyTime   = maxReadyTime,
		totalUnits     = #salvoElements,
		isSilo         = isSiloBarrage,
		isSingleUnit   = singleUnitRepeats,
		pStart         = pStart,
		pEnd           = pEnd,
		isArea         = isArea,
	}
end

--------------------------------------------------------------------------------
-- DISPATCHER & TOT QUEUE HANDLER
--------------------------------------------------------------------------------
local function ExecuteCarpetBarrage(plan, shiftHeld)
	if not plan or not plan.elements then return end

	local currentFrame = spGetGameFrame()
	local pending = {}

	for i = 1, #plan.elements do
		local elem = plan.elements[i]
		local cmdToIssue = plan.commandID
		if plan.isSilo then
			local siloCmd = GetUnitCommandIDByName(elem.unitID, "launch")
			if siloCmd then cmdToIssue = siloCmd end
		end

		local opts = {}
		if shiftHeld or elem.isQueued then
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

	pcall(spPlaySoundFile, "beep4", 0.70, "ui")
	if spEcho then
		spEcho(string.format("[Carpet Barrage] Salvo deployed: %d warheads synchronized!", #plan.elements))
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
-- MOUSE & COMMAND HOOKS
--------------------------------------------------------------------------------
function widget:MousePress(mx, my, button)
	if spIsGUIHidden and spIsGUIHidden() then return false end

	local alt, ctrl, meta, shift = spGetModKeyState()

	-- Alt + Right-Click Drag shortcut
	if button == 3 and alt then
		local sel = spGetSelectedUnits()
		if sel and #sel >= 1 then
			local gpos, tid = GetGroundPosFromMouse(mx, my)
			if gpos then
				isDragging = true
				hasDraggedPastThreshold = false
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

	-- Intercepting Active In-Game Command (Attack, Set Target, Launch)
	if button == 1 then
		local cmdIndex, activeCmdID, _, activeCmdName = spGetActiveCommand()
		if IsCarpetCommand(activeCmdID, activeCmdName, cmdIndex) then
			local sel = spGetSelectedUnits()
			if sel and #sel >= 1 then
				local gpos, tid = GetGroundPosFromMouse(mx, my)
				if gpos then
					isDragging = true
					hasDraggedPastThreshold = false
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
		else
			activeBarragePreview = nil
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
		-- Single click passthrough
		local sel = spGetSelectedUnits()
		if sel and #sel > 0 then
			local options = dragShiftHeld and { "shift" } or {}
			local targetParams = nil
			if dragTargetUnitID then
				targetParams = { dragTargetUnitID }
			elseif dragStartWorld then
				targetParams = dragStartWorld
			end

			if targetParams then
				local cmdToIssue = dragCommandID
				local uid = sel[1]
				local siloCmd = GetUnitCommandIDByName(uid, "launch")
				if siloCmd then cmdToIssue = siloCmd end

				for i = 1, #sel do
					spGiveOrderToUnit(sel[i], cmdToIssue, targetParams, options)
				end
			end
		end
		spSetActiveCommand(0)
	end

	isDragging = false
	dragStartWorld = nil
	dragCurrentWorld = nil
	activeBarragePreview = nil
	hasDraggedPastThreshold = false
	dragTargetUnitID = nil

	return true
end

--------------------------------------------------------------------------------
-- 3D HOLOGRAPHIC WORLD RENDERING
--------------------------------------------------------------------------------
local function DrawGroundRing(cx, cy, cz, radius, r, g, b, a)
	local segments = 32
	local step = TWO_PI / segments

	glColor(r, g, b, a * 0.22)
	glBeginEnd(GL_TRIANGLE_FAN, function()
		glVertex(cx, cy + 4, cz)
		for i = 0, segments do
			local angle = i * step
			local px = cx + cos(angle) * radius
			local pz = cz + sin(angle) * radius
			local py = spGetGroundHeight(px, pz) + 4
			glVertex(px, py, pz)
		end
	end)

	glColor(r, g, b, a)
	glLineWidth(2.4)
	glBeginEnd(GL_LINE_LOOP, function()
		for i = 0, segments - 1 do
			local angle = i * step
			local px = cx + cos(angle) * radius
			local pz = cz + sin(angle) * radius
			local py = spGetGroundHeight(px, pz) + 5
			glVertex(px, py, pz)
		end
	end)
end

local function DrawParabolicLaserArc(pStart, pEnd, r, g, b, a)
	local segments = 24
	local dx = pEnd[1] - pStart[1]
	local dy = pEnd[2] - pStart[2]
	local dz = pEnd[3] - pStart[3]
	local dist = sqrt(dx * dx + dz * dz)
	local arcHeight = max(80, dist * 0.25)

	glLineWidth(2.2)
	glBeginEnd(GL_LINE_STRIP, function()
		for i = 0, segments do
			local t = i / segments
			local px = pStart[1] + dx * t
			local pz = pStart[3] + dz * t
			local py = pStart[2] + dy * t + sin(t * pi) * arcHeight
			local alpha = a * (0.35 + sin(t * pi) * 0.65)
			glColor(r, g, b, alpha)
			glVertex(px, py, pz)
		end
	end)
end

function widget:DrawWorld()
	if not activeBarragePreview or not activeBarragePreview.elements then return end

	local gameSecs = spGetGameSeconds()
	local pulse = 0.85 + 0.15 * sin(gameSecs * 6.0)

	glDepthTest(false)

	local elems = activeBarragePreview.elements
	local isSilo = activeBarragePreview.isSilo
	local ringR = isSilo and 1.0 or 0.2
	local ringG = isSilo and 0.4 or 0.95
	local ringB = isSilo and 0.1 or 1.0

	for i = 1, #elems do
		local elem = elems[i]
		local tp = elem.targetPos
		local up = elem.unitPos

		DrawGroundRing(tp[1], tp[2], tp[3], elem.aoe, ringR, ringG, ringB, 0.85 * pulse)

		local chSize = elem.aoe * 0.45
		glColor(ringR, ringG, ringB, 0.8 * pulse)
		glLineWidth(1.8)
		glBeginEnd(GL_LINES, function()
			glVertex(tp[1] - chSize, tp[2] + 5, tp[3])
			glVertex(tp[1] + chSize, tp[2] + 5, tp[3])
			glVertex(tp[1], tp[2] + 5, tp[3] - chSize)
			glVertex(tp[1], tp[2] + 5, tp[3] + chSize)
		end)

		DrawParabolicLaserArc(up, tp, ringR, ringG, ringB, 0.75)
	end

	if #elems >= 2 then
		glColor(ringR, ringG, ringB, 0.65)
		glLineWidth(2.2)
		glBeginEnd(GL_LINE_STRIP, function()
			for i = 1, #elems do
				local tp = elems[i].targetPos
				glVertex(tp[1], tp[2] + 7, tp[3])
			end
		end)
	end

	glDepthTest(true)
	glColor(1, 1, 1, 1)
	glLineWidth(1.0)
end

--------------------------------------------------------------------------------
-- 2D SCREEN HUD (GLASSMORPHIC TACTICAL OVERLAY)
--------------------------------------------------------------------------------
function widget:DrawScreen()
	if not activeBarragePreview then return end

	local vsx, vsy = spGetViewGeometry()
	local hudW = 380
	local hudH = 82
	local hudX = (vsx - hudW) * 0.5
	local hudY = vsy - 120

	local isSilo = activeBarragePreview.isSilo
	local borderR = isSilo and 1.0 or 0.2
	local borderG = isSilo and 0.45 or 0.9
	local borderB = isSilo and 0.1 or 1.0

	-- Backdrop Glass
	glColor(0.015, 0.04, 0.08, 0.88)
	glRect(hudX, hudY, hudX + hudW, hudY + hudH)

	-- Glowing Border
	glColor(borderR, borderG, borderB, 0.9)
	glLineWidth(2.0)
	glBeginEnd(GL_LINE_LOOP, function()
		glVertex(hudX, hudY)
		glVertex(hudX + hudW, hudY)
		glVertex(hudX + hudW, hudY + hudH)
		glVertex(hudX, hudY + hudH)
	end)

	-- Header Title
	local title = isSilo and "NUCLEAR / MISSILE CARPET BARRAGE" or (activeBarragePreview.isArea and "HEXAGONAL CARPET BARRAGE (TOT)" or "LINEAR CARPET BARRAGE (TOT)")
	glColor(borderR, borderG, borderB, 1.0)
	glText(title, hudX + 16, hudY + 52, 13, "o")

	-- Detailed Salvo Info
	local infoText = string.format("SALVO WARHEADS: %d  |  TOT IMPACT: %.1fs", activeBarragePreview.totalUnits, activeBarragePreview.maxReadyTime)
	glColor(0.85, 0.95, 1.0, 0.95)
	glText(infoText, hudX + 16, hudY + 32, 11, "o")

	local hintText = isSilo and "Release to launch missile salvo  |  Hold Ctrl for Hex-Grid" or "Release to fire salvo  |  Hold Ctrl for Hex-Grid"
	glColor(0.6, 0.8, 0.95, 0.75)
	glText(hintText, hudX + 16, hudY + 12, 10, "o")

	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- SHUTDOWN CLEANUP
--------------------------------------------------------------------------------
function widget:Shutdown()
	pendingSalvos = {}
	activeBarragePreview = nil
	unitWeaponCache = {}
	isDragging = false
end
