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
local spGetGroundHeight        = Spring.GetGroundHeight
local spGetGroundNormal        = Spring.GetGroundNormal
local spTraceScreenRay         = Spring.TraceScreenRay
local spGetActiveCommand       = Spring.GetActiveCommand
local spSetActiveCommand       = Spring.SetActiveCommand
local spGiveOrderToUnit        = Spring.GiveOrderToUnit
local spGetGameFrame           = Spring.GetGameFrame
local spGetGameSeconds         = Spring.GetGameSeconds
local spGetCameraPosition      = Spring.GetCameraPosition
local spGetViewGeometry        = Spring.GetViewGeometry
local spGetModKeyState         = Spring.GetModKeyState
local spPlaySoundFile          = Spring.PlaySoundFile
local spWorldToScreenCoords    = Spring.WorldToScreenCoords

local glColor                  = gl.Color
local glLineWidth              = gl.LineWidth
local glBeginEnd               = gl.BeginEnd
local glVertex                 = gl.Vertex
local glPushMatrix             = gl.PushMatrix
local glPopMatrix              = gl.PopMatrix
local glTranslate              = gl.Translate
local glRotate                 = gl.Rotate
local glScale                  = gl.Scale
local glDepthTest              = gl.DepthTest
local glPolygonMode            = gl.PolygonMode
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
local CMD_STOCKPILE            = (CMD and CMD.STOCKPILE) or 100
local CMD_WAIT                 = CMD.WAIT or 25
local CMD_FIRE_STATE           = CMD.FIRE_STATE or 45

local DRAG_DIST_THRESHOLD      = 45 -- World elmos before engaging carpet barrage
local GRAVITY_CONSTANT         = 130.0 -- Spring engine standard gravity magnitude

--------------------------------------------------------------------------------
-- STATE VARIABLES
--------------------------------------------------------------------------------
local isDragging               = false
local dragStartWorld           = nil
local dragCurrentWorld         = nil
local dragCommandID            = CMD_ATTACK
local isAreaMode               = false
local isAltRightDrag           = false

local activeBarragePreview     = nil
local pendingSalvos            = {} -- Queue of scheduled TOT fire events
local unitWeaponCache          = {}

--------------------------------------------------------------------------------
-- WEAPON & BALLISTICS ENGINE
--------------------------------------------------------------------------------
local function GetUnitWeaponInfo(unitDefID)
	if unitWeaponCache[unitDefID] ~= nil then
		return unitWeaponCache[unitDefID]
	end

	local udef = UnitDefs[unitDefID]
	if not udef or not udef.weapons or #udef.weapons == 0 then
		unitWeaponCache[unitDefID] = false
		return false
	end

	-- Scan weapons to find the primary long-range ballistic / rocket / plasma weapon
	local bestWeapon = nil
	local maxRange = 0

	for i = 1, #udef.weapons do
		local w = udef.weapons[i]
		if w and w.weaponDef then
			local wdef = WeaponDefs[w.weaponDef]
			if wdef and wdef.range and wdef.range > maxRange then
				-- Filter out AA-only or shield-only weapons
				local isAA = wdef.onlyTargets and wdef.onlyTargets.air
				if not isAA and wdef.range >= 350 then
					maxRange = wdef.range
					bestWeapon = wdef
				end
			end
		end
	end

	if not bestWeapon then
		unitWeaponCache[unitDefID] = false
		return false
	end

	local info = {
		name         = bestWeapon.name or "Artillery",
		range        = bestWeapon.range or 800,
		minRange     = bestWeapon.minRange or 0,
		aoe          = max(32, bestWeapon.damageAreaOfEffect or 48),
		projSpeed    = max(100, bestWeapon.projectilespeed or 350),
		isBallistic  = (bestWeapon.type == "Cannon" or bestWeapon.type == "MissileLauncher"),
		highTraj     = bestWeapon.trajectoryHeight and (bestWeapon.trajectoryHeight > 0),
		turnRate     = max(0.2, (udef.turnRate or 300) * DEG_TO_RAD),
		accuracy     = bestWeapon.accuracy or 0,
	}

	unitWeaponCache[unitDefID] = info
	return info
end

--- Solves the exact ballistic time of flight under Spring engine gravity
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
		-- Target out of pure ballistic range, fallback to direct velocity
		local totalDist = sqrt(horizDist * horizDist + dy * dy)
		return max(0.1, totalDist / v)
	end

	local sqrtDisc = sqrt(discriminant)
	local root = highTraj and (v2 + sqrtDisc) or (v2 - sqrtDisc)
	local tanTheta = root / (g * horizDist)
	local theta = atan2(root, g * horizDist)
	local cosTheta = cos(theta)

	local vHoriz = max(10, v * cosTheta)
	local flightTime = horizDist / vHoriz
	return max(0.1, flightTime)
end

--- Solves turret slew/traverse time to align with target heading
local function SolveTurretSlewTime(unitX, unitZ, unitHeadingSpring, targetX, targetZ, turnRate)
	local desiredAngle = atan2(targetX - unitX, targetZ - unitZ)
	local currentAngle = unitHeadingSpring * SPRING_HEADING_SCALE

	local diff = desiredAngle - currentAngle
	while diff > pi do diff = diff - TWO_PI end
	while diff < -pi do diff = diff + TWO_PI end

	local absDiff = abs(diff)
	return absDiff / max(0.1, turnRate)
end

--------------------------------------------------------------------------------
-- SPATIAL TESSELLATION & PACKING (HEXAGONAL & LINEAR)
--------------------------------------------------------------------------------
local function GenerateLinearTessellation(pStart, pEnd, count, avgAoE)
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

	local spacing = max(avgAoE * 1.5, 45)
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
		if ring > 10 then break end -- Safety cap
	end

	return points
end

--------------------------------------------------------------------------------
-- TOPOLOGICAL ZERO-CRISSCROSS MATCHING
--------------------------------------------------------------------------------
local function MatchUnitsToTargetsZeroCrisscross(units, targets, dirVector)
	local count = min(#units, #targets)
	if count <= 0 then return {} end

	local uDirX = dirVector[1]
	local uDirZ = dirVector[2]

	-- 1. Decorate units with scalar projections
	local decoratedUnits = {}
	for i = 1, #units do
		local u = units[i]
		local proj = (u.pos[1] * uDirX) + (u.pos[3] * uDirZ)
		decoratedUnits[i] = { unit = u, proj = proj }
	end

	-- 2. Decorate targets with scalar projections along same axis
	local decoratedTargets = {}
	for j = 1, #targets do
		local t = targets[j]
		local proj = (t[1] * uDirX) + (t[3] * uDirZ)
		decoratedTargets[j] = { target = t, proj = proj }
	end

	-- 3. Sort both sets strictly along the projection axis
	table.sort(decoratedUnits, function(a, b) return a.proj < b.proj end)
	table.sort(decoratedTargets, function(a, b) return a.proj < b.proj end)

	-- 4. Pair 1-to-1: strictly parallel lines of fire with zero crisscrossing
	local pairings = {}
	for k = 1, count do
		pairings[k] = {
			unit   = decoratedUnits[k].unit,
			target = decoratedTargets[k].target,
		}
	end

	return pairings
end

--------------------------------------------------------------------------------
-- CARPET BARRAGE SOLVER (BUILD FULL SALVO BLUEPRINT)
--------------------------------------------------------------------------------
local function BuildCarpetBarragePlan(cmdID, pStart, pEnd, isArea)
	local rawSelected = spGetSelectedUnits()
	if not rawSelected or #rawSelected < 2 then return nil end

	-- 1. Filter valid artillery/combat units
	local validUnits = {}
	local totalAoE = 0

	for i = 1, #rawSelected do
		local uid = rawSelected[i]
		local udefID = spGetUnitDefID(uid)
		if udefID then
			local winfo = GetUnitWeaponInfo(udefID)
			if winfo then
				local ux, uy, uz = spGetUnitPosition(uid)
				local uheading = spGetUnitHeading(uid) or 0
				validUnits[#validUnits + 1] = {
					id       = uid,
					pos      = { ux, uy, uz },
					heading  = uheading,
					winfo    = winfo,
				}
				totalAoE = totalAoE + winfo.aoe
			end
		end
	end

	local numUnits = #validUnits
	if numUnits < 2 then return nil end
	local avgAoE = totalAoE / numUnits

	-- 2. Generate Tessellated Target Points
	local targets = {}
	local dirX, dirZ

	if isArea then
		local dx = pEnd[1] - pStart[1]
		local dz = pEnd[3] - pStart[3]
		local rad = max(avgAoE * 1.5, sqrt(dx * dx + dz * dz))
		targets = GenerateHexagonalTessellation(pStart, rad, numUnits, avgAoE)
		dirX = dx
		dirZ = dz
	else
		targets = GenerateLinearTessellation(pStart, pEnd, numUnits, avgAoE)
		dirX = pEnd[1] - pStart[1]
		dirZ = pEnd[3] - pStart[3]
	end

	local dirLen = sqrt(dirX * dirX + dirZ * dirZ)
	if dirLen < 0.001 then
		dirX, dirZ = 1, 0
	else
		dirX, dirZ = dirX / dirLen, dirZ / dirLen
	end

	-- 3. Match Units to Targets (Zero-Crisscross)
	local pairings = MatchUnitsToTargetsZeroCrisscross(validUnits, targets, { dirX, dirZ })
	if #pairings == 0 then return nil end

	-- 4. Calculate Ballistics & TOT Timings
	local maxReadyTime = 0
	local salvoElements = {}

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
		}
	end

	-- 5. Calculate Exact Frame Delays for Simultaneous Detonation
	local currentFrame = spGetGameFrame()
	for k = 1, #salvoElements do
		local elem = salvoElements[k]
		local fireDelaySec = maxReadyTime - elem.readyTime
		elem.delayFrames = max(0, floor(fireDelaySec * 30))
		elem.fireFrame   = currentFrame + elem.delayFrames
	end

	return {
		commandID      = cmdID,
		elements       = salvoElements,
		maxReadyTime   = maxReadyTime,
		totalUnits     = #salvoElements,
		pStart         = pStart,
		pEnd           = pEnd,
		isArea         = isArea,
		createdFrame   = currentFrame,
	}
end

--------------------------------------------------------------------------------
-- DISPATCHER & TOT QUEUE HANDLER
--------------------------------------------------------------------------------
local function ExecuteCarpetBarrage(plan)
	if not plan or not plan.elements then return end

	local currentFrame = spGetGameFrame()
	local pending = {}

	for i = 1, #plan.elements do
		local elem = plan.elements[i]
		if elem.fireFrame <= currentFrame then
			-- Fire immediately on this frame
			spGiveOrderToUnit(elem.unitID, plan.commandID, elem.targetPos, {})
		else
			-- Queue for sub-tick synchronized release
			pending[#pending + 1] = {
				unitID    = elem.unitID,
				cmdID     = plan.commandID,
				targetPos = elem.targetPos,
				fireFrame = elem.fireFrame,
			}
		end
	end

	if #pending > 0 then
		pendingSalvos[#pendingSalvos + 1] = pending
	end

	spPlaySoundFile("sounds/ui/build_done.wav", 1.0, nil, nil, nil, "ui")
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
					spGiveOrderToUnit(item.unitID, item.cmdID, item.targetPos, {})
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
-- RAYCAST GROUND HELPER
--------------------------------------------------------------------------------
local function ScreenToGround(mx, my)
	local _, pos = spTraceScreenRay(mx, my, true, true)
	if pos then
		return pos
	end
	return nil
end

--------------------------------------------------------------------------------
-- MOUSE & COMMAND HOOKS ("กดที่ปุ่มเดิมเลย")
--------------------------------------------------------------------------------
function widget:MousePress(mx, my, button)
	local alt, ctrl, meta, shift = spGetModKeyState()

	-- Alt + Right-Click Drag shortcut
	if button == 3 and alt then
		local gpos = ScreenToGround(mx, my)
		if gpos then
			isDragging = true
			isAltRightDrag = true
			dragCommandID = CMD_ATTACK
			dragStartWorld = gpos
			dragCurrentWorld = gpos
			isAreaMode = ctrl
			activeBarragePreview = nil
			return true
		end
	end

	-- Intercepting Active In-Game Command (Attack, Set Target, Launch)
	if button == 1 then
		local _, activeCmdID = spGetActiveCommand()
		if activeCmdID == CMD_ATTACK or activeCmdID == CMD_SET_TARGET or activeCmdID == CMD_STOCKPILE then
			local sel = spGetSelectedUnits()
			if sel and #sel >= 2 then
				local gpos = ScreenToGround(mx, my)
				if gpos then
					isDragging = true
					isAltRightDrag = false
					dragCommandID = activeCmdID
					dragStartWorld = gpos
					dragCurrentWorld = gpos
					isAreaMode = ctrl
					activeBarragePreview = nil
					-- Don't consume yet; allow short click to fallback naturally
				end
			end
		end
	end

	return false
end

function widget:MouseMove(mx, my, dx, dy, button)
	if not isDragging or not dragStartWorld then return false end

	local gpos = ScreenToGround(mx, my)
	if gpos then
		dragCurrentWorld = gpos
		local _, ctrl = spGetModKeyState()
		isAreaMode = ctrl

		local dX = dragCurrentWorld[1] - dragStartWorld[1]
		local dZ = dragCurrentWorld[3] - dragStartWorld[3]
		local dist = sqrt(dX * dX + dZ * dZ)

		if dist >= DRAG_DIST_THRESHOLD then
			activeBarragePreview = BuildCarpetBarragePlan(dragCommandID, dragStartWorld, dragCurrentWorld, isAreaMode)
		else
			activeBarragePreview = nil
		end
	end

	return false
end

function widget:MouseRelease(mx, my, button)
	if not isDragging then return false end

	local handled = false
	if activeBarragePreview and activeBarragePreview.totalUnits >= 2 then
		ExecuteCarpetBarrage(activeBarragePreview)
		-- Consume active command so standard single attack doesn't duplicate
		spSetActiveCommand(0)
		handled = true
	end

	isDragging = false
	dragStartWorld = nil
	dragCurrentWorld = nil
	activeBarragePreview = nil
	isAltRightDrag = false

	return handled
end

--------------------------------------------------------------------------------
-- 3D HOLOGRAPHIC WORLD RENDERING
--------------------------------------------------------------------------------
local function DrawGroundRing(cx, cy, cz, radius, r, g, b, a)
	local segments = 32
	local step = TWO_PI / segments

	glColor(r, g, b, a * 0.2)
	glBeginEnd(GL_TRIANGLE_FAN, function()
		glVertex(cx, cy + 2, cz)
		for i = 0, segments do
			local angle = i * step
			local px = cx + cos(angle) * radius
			local pz = cz + sin(angle) * radius
			local py = spGetGroundHeight(px, pz) + 2
			glVertex(px, py, pz)
		end
	end)

	glColor(r, g, b, a)
	glLineWidth(2.0)
	glBeginEnd(GL_LINE_LOOP, function()
		for i = 0, segments - 1 do
			local angle = i * step
			local px = cx + cos(angle) * radius
			local pz = cz + sin(angle) * radius
			local py = spGetGroundHeight(px, pz) + 3
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
	local arcHeight = max(60, dist * 0.25)

	glLineWidth(1.8)
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
	for i = 1, #elems do
		local elem = elems[i]
		local tp = elem.targetPos
		local up = elem.unitPos

		-- 1. Holographic Impact Zone
		DrawGroundRing(tp[1], tp[2], tp[3], elem.aoe, 0.2, 0.9, 1.0, 0.85 * pulse)

		-- 2. Inner Crosshair
		local chSize = elem.aoe * 0.4
		glColor(0.3, 1.0, 0.9, 0.7 * pulse)
		glLineWidth(1.5)
		glBeginEnd(GL_LINES, function()
			glVertex(tp[1] - chSize, tp[2] + 4, tp[3])
			glVertex(tp[1] + chSize, tp[2] + 4, tp[3])
			glVertex(tp[1], tp[2] + 4, tp[3] - chSize)
			glVertex(tp[1], tp[2] + 4, tp[3] + chSize)
		end)

		-- 3. Parabolic Trajectory Arc from Muzzle to Target
		DrawParabolicLaserArc(up, tp, 0.1, 0.85, 1.0, 0.7)
	end

	-- Connecting Barrage Boundary
	if #elems >= 2 then
		glColor(0.2, 0.95, 1.0, 0.5)
		glLineWidth(2.0)
		glBeginEnd(GL_LINE_STRIP, function()
			for i = 1, #elems do
				local tp = elems[i].targetPos
				glVertex(tp[1], tp[2] + 5, tp[3])
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
	local hudW = 340
	local hudH = 75
	local hudX = (vsx - hudW) * 0.5
	local hudY = vsy - 120

	-- Backdrop Glass
	glColor(0.02, 0.05, 0.09, 0.82)
	glRect(hudX, hudY, hudX + hudW, hudY + hudH)

	-- Glowing Cyan Border
	glColor(0.18, 0.85, 1.0, 0.85)
	glLineWidth(1.5)
	glBeginEnd(GL_LINE_LOOP, function()
		glVertex(hudX, hudY)
		glVertex(hudX + hudW, hudY)
		glVertex(hudX + hudW, hudY + hudH)
		glVertex(hudX, hudY + hudH)
	end)

	-- Header Title
	local title = activeBarragePreview.isArea and "HEXAGONAL CARPET BARRAGE (TOT)" or "LINEAR CARPET BARRAGE (TOT)"
	glText(title, hudX + 16, hudY + 48, 13, "o")

	-- Detailed Salvo Info
	local infoText = string.format("UNITS SYNCED: %d  |  TOT IMPACT: %.1fs", activeBarragePreview.totalUnits, activeBarragePreview.maxReadyTime)
	glColor(0.7, 0.92, 1.0, 0.9)
	glText(infoText, hudX + 16, hudY + 28, 11, "o")

	local hintText = "Release to fire volley  |  Hold Ctrl for Area Hex-Grid"
	glColor(0.5, 0.75, 0.9, 0.7)
	glText(hintText, hudX + 16, hudY + 12, 9, "o")

	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- SHUTDOWN CLEANUP
--------------------------------------------------------------------------------
function widget:Shutdown()
	pendingSalvos = {}
	activeBarragePreview = nil
	unitWeaponCache = {}
end
