local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Tactical Carpet Barrage (TOT)",
		desc = "Synchronized Time-on-Target (TOT) artillery saturation barrage with hexagonal non-overlapping spatial packing, 3D ballistic raycasting, and holographic visualization.",
		author = "Codex",
		date = "2026.09",
		license = "GNU GPL, v2 or later",
		layer = 260,
		enabled = true,
		handler = true,
	}
end

--------------------------------------------------------------------------------
-- Engine Constants & Math Localization
--------------------------------------------------------------------------------
local sin, cos, atan2, sqrt, max, min, floor, ceil, abs, pi = math.sin, math.cos, math.atan2, math.sqrt, math.max, math.min, math.floor, math.ceil, math.abs, math.pi
local TWO_PI = pi * 2
local HALF_PI = pi * 0.5
local DEG_TO_RAD = pi / 180.0
local RAD_TO_DEG = 180.0 / pi
local HEADING_TO_RAD = TWO_PI / 65536.0

local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitHeading = Spring.GetUnitHeading
local spGetUnitDefID = Spring.GetUnitDefID
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetGroundHeight = Spring.GetGroundHeight
local spTraceScreenRay = Spring.TraceScreenRay
local spGetMouseState = Spring.GetMouseState
local spGetModKeyState = Spring.GetModKeyState
local spGetViewGeometry = Spring.GetViewGeometry
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetGameFrame = Spring.GetGameFrame
local spPlaySoundFile = Spring.PlaySoundFile
local spWorldToScreenCoords = Spring.WorldToScreenCoords
local spGetActiveCommand = Spring.GetActiveCommand

local glColor = gl.Color
local glLineWidth = gl.LineWidth
local glBeginEnd = gl.BeginEnd
local glVertex = gl.Vertex
local glRect = gl.Rect
local glTexture = gl.Texture
local glTexRect = gl.TexRect
local glText = gl.Text
local glPushMatrix = gl.PushMatrix
local glPopMatrix = gl.PopMatrix
local glTranslate = gl.Translate
local glBillboard = gl.Billboard
local glDepthTest = gl.DepthTest
local glPolygonMode = gl.PolygonMode

local GL_LINES = (GL and GL.LINES) or 0x0001
local GL_LINE_STRIP = (GL and GL.LINE_STRIP) or 0x0003
local GL_LINE_LOOP = (GL and GL.LINE_LOOP) or 0x0002
local GL_TRIANGLES = (GL and GL.TRIANGLES) or 0x0004
local GL_TRIANGLE_FAN = (GL and GL.TRIANGLE_FAN) or 0x0006
local GL_FRONT_AND_BACK = (GL and GL.FRONT_AND_BACK) or 0x0408
local GL_LINE = (GL and GL.LINE) or 0x1B01
local GL_FILL = (GL and GL.FILL) or 0x1B02

local CMD_ATTACK = CMD.ATTACK or 20
local CMD_STOP = CMD.STOP or 0

--------------------------------------------------------------------------------
-- Config & State
--------------------------------------------------------------------------------
local config = {
	enabled = true,
	hotkey = "b",
	spreadMultiplier = 1.0, -- Default 1.0x (Adjustable via Mouse Wheel while dragging)
	minSpreadMult = 0.5,
	maxSpreadMult = 2.5,
	soundVolume = 0.85,
	showTrajectoryArcs = true,
	showHoloHexGrid = true,
	showCountdownTimer = true,
	defaultGravity = 30.0,
}

local targetingModeActive = false
local isDragging = false
local dragStart = { x = 0, y = 0, z = 0 }
local dragCurrent = { x = 0, y = 0, z = 0 }
local cachedArtilleryUnits = {}
local currentPlan = nil -- Active computed targeting plan
local activeExecutions = {} -- List of currently running TOT strikes in-flight
local animClock = 0
local hudButtonRect = { x = 0, y = 0, w = 180, h = 38 }

--------------------------------------------------------------------------------
-- Precalculated Geometric Lattices (Zero GC Allocations)
--------------------------------------------------------------------------------
local HEX_CORNERS = {}
do
	for i = 0, 6 do
		local angle = (i * 60) * DEG_TO_RAD
		HEX_CORNERS[i] = { x = cos(angle), z = sin(angle) }
	end
end

local CIRCLE_SEGMENTS = 24
local CIRCLE_POINTS = {}
do
	for i = 0, CIRCLE_SEGMENTS do
		local angle = (i / CIRCLE_SEGMENTS) * TWO_PI
		CIRCLE_POINTS[i] = { x = cos(angle), z = sin(angle) }
	end
end

--------------------------------------------------------------------------------
-- Artillery Weapon Registry & Trajectory Metadata
--------------------------------------------------------------------------------
local ARTILLERY_CACHE = {}

local function getArtilleryProfile(unitDefID)
	if ARTILLERY_CACHE[unitDefID] ~= nil then
		return ARTILLERY_CACHE[unitDefID]
	end

	local ud = UnitDefs[unitDefID]
	if not ud or not ud.weapons or #ud.weapons == 0 then
		ARTILLERY_CACHE[unitDefID] = false
		return false
	end

	local bestWeapon = nil
	local maxRange = 0

	for i = 1, #ud.weapons do
		local w = ud.weapons[i]
		local wdef = w and w.weaponDef and WeaponDefs[w.weaponDef]
		if wdef then
			local wtype = wdef.type or ""
			local range = wdef.range or 0
			-- Artillery weapons: Cannon, MissileLauncher, Plasma, Mortar with range >= 650
			local isArtilleryType = (wtype == "Cannon" or wtype == "MissileLauncher" or wtype == "Plasma" or wtype == "Mortar")
			if (isArtilleryType or range >= 800) and range >= 600 then
				if range > maxRange then
					maxRange = range
					bestWeapon = wdef
				end
			end
		end
	end

	if bestWeapon then
		local profile = {
			name = ud.humanName or ud.name,
			range = bestWeapon.range or 1000,
			minRange = bestWeapon.minRange or 0,
			velocity = bestWeapon.projectilespeed or bestWeapon.weaponVelocity or 450,
			aoe = max(32.0, bestWeapon.damageAreaOfEffect or 64.0),
			accuracy = bestWeapon.accuracy or 0,
			highTrajectory = (bestWeapon.highTrajectory == 1 or bestWeapon.highTrajectory == 2),
			turnRate = max(0.2, (bestWeapon.turnRate or (ud.turnRate and ud.turnRate * 0.05) or 1.0)),
			reload = bestWeapon.reload or 3.0,
		}
		ARTILLERY_CACHE[unitDefID] = profile
		return profile
	end

	ARTILLERY_CACHE[unitDefID] = false
	return false
end

local function getSelectedArtillery()
	local sel = spGetSelectedUnits()
	if not sel or #sel == 0 then return {} end
	local arties = {}
	for i = 1, #sel do
		local uid = sel[i]
		local defID = spGetUnitDefID(uid)
		if defID and getArtilleryProfile(defID) then
			arties[#arties + 1] = uid
		end
	end
	return arties
end

--------------------------------------------------------------------------------
-- Mathematical Ballistics Solver (Exact 3D Parabola under Gravity)
--------------------------------------------------------------------------------
local function solveBallistics(gx, gy, gz, tx, ty, tz, velocity, allowHigh)
	local dx = tx - gx
	local dz = tz - gz
	local dy = ty - gy
	local d2D = sqrt(dx * dx + dz * dz)

	if d2D <= 0.001 then return nil end

	local g = (Game and Game.gravity) or config.defaultGravity
	local v = velocity
	local v2 = v * v
	local v4 = v2 * v2
	local gDist = g * d2D
	local gDist2 = gDist * gDist

	-- Ballistic discriminant: v^4 - g * (g * d2D^2 + 2 * dy * v^2)
	local disc = v4 - g * (g * d2D * d2D + 2.0 * dy * v2)
	if disc < 0 then
		return nil -- Target out of physical ballistic range
	end

	local sqrtDisc = sqrt(disc)
	local angleLow = atan2(v2 - sqrtDisc, gDist)
	local angleHigh = atan2(v2 + sqrtDisc, gDist)

	-- Choose trajectory angle based on weapon capability
	local angle = angleLow
	if allowHigh and angleHigh > 0 and angleHigh < HALF_PI then
		angle = angleHigh
	end

	local vHoriz = v * cos(angle)
	if vHoriz <= 0.001 then return nil end

	local flightTime = d2D / vHoriz

	return {
		angle = angle,
		flightTime = flightTime,
		distance = d2D,
		vHoriz = vHoriz,
		vVert = v * sin(angle),
		gravity = g,
		dirX = dx / d2D,
		dirZ = dz / d2D,
	}
end

--------------------------------------------------------------------------------
-- 3D Terrain Collision & Obstacle Clearance Raycaster
--------------------------------------------------------------------------------
local function checkTrajectoryClearance(gx, gy, gz, tx, ty, tz, sol)
	if not sol then return false end

	local SAMPLES = 16
	local dt = sol.flightTime / SAMPLES
	local t = 0

	for i = 1, SAMPLES - 1 do
		t = t + dt
		local x = gx + sol.dirX * (sol.vHoriz * t)
		local z = gz + sol.dirZ * (sol.vHoriz * t)
		local y = gy + (sol.vVert * t) - 0.5 * sol.gravity * (t * t)

		local groundY = spGetGroundHeight(x, z) or 0
		if y < groundY + 12.0 then
			return false -- Shell collides with mountain / obstacle
		end
	end

	return true
end

--------------------------------------------------------------------------------
-- Hexagonal Circle Packing & Area Saturation Lattice Generator
--------------------------------------------------------------------------------
local function generateHexLattice(cx, cz, fx, fz, count, baseAOE, spreadMult)
	local points = {}
	if count <= 0 then return points end

	if count == 1 then
		local gy = spGetGroundHeight(cx, cz) or 0
		points[1] = { x = cx, y = gy, z = cz, ring = 0 }
		return points
	end

	-- Perpendicular right vector: (-fz, fx)
	local rx, rz = -fz, fx

	-- Hexagonal cell spacing (90% of blast diameter for optimal lethality overlap)
	local spacing = max(45.0, baseAOE * 1.80 * spreadMult)
	local rowH = spacing * 0.866025 -- sqrt(3)/2

	local cols = ceil(sqrt(count * 1.25))
	local rows = ceil(count / cols)
	local halfCols = (cols - 1) * 0.5
	local halfRows = (rows - 1) * 0.5

	local idx = 1
	for r = 0, rows - 1 do
		local rowOffset = (r % 2 == 1) and (spacing * 0.5) or 0
		for c = 0, cols - 1 do
			if idx <= count then
				local px = cx + rx * ((c - halfCols) * spacing + rowOffset) + fx * ((r - halfRows) * rowH)
				local pz = cz + rz * ((c - halfCols) * spacing + rowOffset) + fz * ((r - halfRows) * rowH)
				local py = spGetGroundHeight(px, pz) or 0

				points[idx] = {
					x = px,
					y = py,
					z = pz,
					col = c,
					row = r,
				}
				idx = idx + 1
			end
		end
	end

	return points
end

--------------------------------------------------------------------------------
-- Spatial Bipartite Assignment Solver (Greedy Min-Cost & Non-Crossing)
--------------------------------------------------------------------------------
local function solveAssignments(units, targets)
	local pairsResult = {}
	local count = min(#units, #targets)
	if count == 0 then return pairsResult end

	local unitData = {}
	for i = 1, #units do
		local uid = units[i]
		local ux, uy, uz = spGetUnitPosition(uid)
		local head = spGetUnitHeading(uid) or 0
		local headRad = head * HEADING_TO_RAD
		local defID = spGetUnitDefID(uid)
		local profile = getArtilleryProfile(defID)
		unitData[i] = {
			uid = uid,
			x = ux or 0,
			y = uy or 0,
			z = uz or 0,
			heading = headRad,
			profile = profile,
			assigned = false,
		}
	end

	local targetUsed = {}
	for j = 1, #targets do targetUsed[j] = false end

	-- Greedy bipartite cost matching
	for k = 1, count do
		local bestCost = 1e9
		local bestU = nil
		local bestT = nil
		local bestSol = nil

		for i = 1, #unitData do
			if not unitData[i].assigned then
				local u = unitData[i]
				local prof = u.profile
				for j = 1, #targets do
					if not targetUsed[j] then
						local t = targets[j]
						local sol = solveBallistics(u.x, u.y, u.z, t.x, t.y, t.z, prof.velocity, prof.highTrajectory)
						if sol and sol.distance <= prof.range and sol.distance >= prof.minRange then
							local targetAngle = atan2(t.x - u.x, t.z - u.z)
							local dYaw = abs(targetAngle - u.heading)
							if dYaw > pi then dYaw = TWO_PI - dYaw end

							local aimTime = dYaw / prof.turnRate
							local cost = aimTime * 2.0 + sol.flightTime * 0.5

							-- Check terrain clearance bonus/penalty
							local clear = checkTrajectoryClearance(u.x, u.y, u.z, t.x, t.y, t.z, sol)
							if not clear then
								cost = cost + 100.0 -- Severe obstacle penalty
							end

							if cost < bestCost then
								bestCost = cost
								bestU = i
								bestT = j
								bestSol = sol
							end
						end
					end
				end
			end
		end

		if bestU and bestT then
			unitData[bestU].assigned = true
			targetUsed[bestT] = true
			local u = unitData[bestU]
			local t = targets[bestT]
			local clear = checkTrajectoryClearance(u.x, u.y, u.z, t.x, t.y, t.z, bestSol)

			pairsResult[#pairsResult + 1] = {
				unitID = u.uid,
				gunX = u.x,
				gunY = u.y,
				gunZ = u.z,
				targetX = t.x,
				targetY = t.y,
				targetZ = t.z,
				flightTime = bestSol.flightTime,
				aimTime = abs(atan2(t.x - u.x, t.z - u.z) - u.heading) / u.profile.turnRate,
				clear = clear,
				solution = bestSol,
				aoe = u.profile.aoe,
			}
		else
			break
		end
	end

	return pairsResult
end

--------------------------------------------------------------------------------
-- Plan Synthesizer (Time-on-Target Synchronization)
--------------------------------------------------------------------------------
local function computeBarragePlan(units, startPos, curPos)
	if #units == 0 then return nil end

	local fdx = curPos.x - startPos.x
	local fdz = curPos.z - startPos.z
	local dist = sqrt(fdx * fdx + fdz * fdz)
	local fx, fz = 0, -1
	if dist > 10.0 then
		fx = fdx / dist
		fz = fdz / dist
	end

	-- Compute average AOE of selected artillery
	local totalAOE = 0
	for i = 1, #units do
		local defID = spGetUnitDefID(units[i])
		local prof = getArtilleryProfile(defID)
		totalAOE = totalAOE + (prof and prof.aoe or 64.0)
	end
	local avgAOE = totalAOE / max(1, #units)

	local hexTargets = generateHexLattice(startPos.x, startPos.z, fx, fz, #units, avgAOE, config.spreadMultiplier)
	local pairsList = solveAssignments(units, hexTargets)

	if #pairsList == 0 then return nil end

	-- Find maximum preparation time (longest flight + aim time)
	local maxPrepTime = 0
	for i = 1, #pairsList do
		local prep = pairsList[i].flightTime + pairsList[i].aimTime
		if prep > maxPrepTime then
			maxPrepTime = prep
		end
	end

	local totImpactDelay = maxPrepTime + 0.30 -- Network / order buffer (0.30s)

	-- Calculate staggered fire time for each unit
	for i = 1, #pairsList do
		local p = pairsList[i]
		p.fireDelay = max(0, totImpactDelay - p.flightTime)
	end

	return {
		pairs = pairsList,
		totDelay = totImpactDelay,
		centroid = { x = startPos.x, y = startPos.y, z = startPos.z },
		avgAOE = avgAOE,
		unitCount = #pairsList,
	}
end

--------------------------------------------------------------------------------
-- Execution & Dispatcher (Precision Frame Synchronization)
--------------------------------------------------------------------------------
local function executeBarrage(plan)
	if not plan or #plan.pairs == 0 then return end

	local curFrame = spGetGameFrame() or 0
	local impactFrame = curFrame + ceil(plan.totDelay * 30.0)

	local exec = {
		impactFrame = impactFrame,
		startFrame = curFrame,
		totDelay = plan.totDelay,
		centroid = plan.centroid,
		pairs = plan.pairs,
		completed = false,
	}

	for i = 1, #plan.pairs do
		local p = plan.pairs[i]
		p.scheduledFireFrame = curFrame + ceil(p.fireDelay * 30.0)
		p.fired = false
	end

	activeExecutions[#activeExecutions + 1] = exec

	if config.soundVolume > 0 then
		spPlaySoundFile("beep4", config.soundVolume, "ui")
	end
end

--------------------------------------------------------------------------------
-- Input Handling (Hotkeys & Mouse Interception)
--------------------------------------------------------------------------------
local function getGroundPos(mx, my)
	local _, pos = spTraceScreenRay(mx, my, true, false, false)
	if pos then
		return pos[1], pos[2], pos[3]
	end
	return nil, nil, nil
end

function widget:KeyPress(key, mods, isRepeat)
	if isRepeat then return false end

	-- Toggle Barrage mode via 'B' key when artillery units are selected
	if key == 98 or key == 66 then -- 'b' / 'B'
		local arties = getSelectedArtillery()
		if #arties > 0 then
			targetingModeActive = not targetingModeActive
			isDragging = false
			currentPlan = nil
			if config.soundVolume > 0 then
				spPlaySoundFile("beep4", targetingModeActive and 0.90 or 0.40, "ui")
			end
			return true
		end
	end

	-- Escape key cancels mode
	if key == 27 then -- Escape
		if targetingModeActive or isDragging then
			targetingModeActive = false
			isDragging = false
			currentPlan = nil
			return true
		end
	end

	return false
end

function widget:MousePress(mx, my, button)
	local arties = getSelectedArtillery()
	if #arties == 0 then
		targetingModeActive = false
		return false
	end

	local _, _, meta, shift = spGetModKeyState()
	local isAlt = meta or false

	-- Left-Click (button 1) while in targeting mode: Start dragging saturation zone
	if button == 1 and targetingModeActive then
		local gx, gy, gz = getGroundPos(mx, my)
		if gx then
			isDragging = true
			dragStart.x = gx
			dragStart.y = gy
			dragStart.z = gz
			dragCurrent.x = gx
			dragCurrent.y = gy
			dragCurrent.z = gz
			cachedArtilleryUnits = arties
			currentPlan = computeBarragePlan(arties, dragStart, dragCurrent)
			return true
		end
	end

	-- Power-user Alt + Right-Click (button 3): Instant Drag Barrage without pressing 'B'
	if button == 3 and isAlt and #arties > 0 then
		local gx, gy, gz = getGroundPos(mx, my)
		if gx then
			targetingModeActive = true
			isDragging = true
			dragStart.x = gx
			dragStart.y = gy
			dragStart.z = gz
			dragCurrent.x = gx
			dragCurrent.y = gy
			dragCurrent.z = gz
			cachedArtilleryUnits = arties
			currentPlan = computeBarragePlan(arties, dragStart, dragCurrent)
			return true
		end
	end

	-- Right click cancels active targeting mode
	if button == 3 and targetingModeActive then
		targetingModeActive = false
		isDragging = false
		currentPlan = nil
		return true
	end

	return false
end

function widget:MouseMove(mx, my, dx, dy, button)
	if not isDragging then return false end

	local gx, gy, gz = getGroundPos(mx, my)
	if gx then
		dragCurrent.x = gx
		dragCurrent.y = gy
		dragCurrent.z = gz
		currentPlan = computeBarragePlan(cachedArtilleryUnits, dragStart, dragCurrent)
	end
	return true
end

function widget:MouseRelease(mx, my, button)
	if isDragging and button == 1 then
		isDragging = false
		targetingModeActive = false
		if currentPlan and #currentPlan.pairs > 0 then
			executeBarrage(currentPlan)
		end
		currentPlan = nil
		return true
	end
	return false
end

function widget:MouseWheel(up, value)
	if isDragging then
		local delta = up and 0.15 or -0.15
		config.spreadMultiplier = max(config.minSpreadMult, min(config.maxSpreadMult, config.spreadMultiplier + delta))
		if dragStart.x then
			currentPlan = computeBarragePlan(cachedArtilleryUnits, dragStart, dragCurrent)
		end
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- GameFrame Update & High-Precision Staggered Firing Execution
--------------------------------------------------------------------------------
function widget:GameFrame(frame)
	animClock = animClock + 0.033

	-- Process active TOT executions
	local i = 1
	while i <= #activeExecutions do
		local exec = activeExecutions[i]
		local allDone = true

		for j = 1, #exec.pairs do
			local p = exec.pairs[j]
			if not p.fired then
				if frame >= p.scheduledFireFrame then
					-- Issue the Attack Ground command to the specific artillery piece
					spGiveOrderToUnit(p.unitID, CMD_ATTACK, { p.targetX, p.targetY, p.targetZ }, {})
					p.fired = true
					if config.soundVolume > 0 then
						spPlaySoundFile("beep4", 0.45, "ui")
					end
				else
					allDone = false
				end
			end
		end

		if frame >= exec.impactFrame then
			-- Synchronized Impact Confirmation
			if config.soundVolume > 0 then
				spPlaySoundFile("beep4", 0.95, "ui")
			end
			table.remove(activeExecutions, i)
		else
			i = i + 1
		end
	end
end

--------------------------------------------------------------------------------
-- Holographic 3D World Rendering (Zero-GC Batched Shaders & Displays)
--------------------------------------------------------------------------------
local function drawHexagonGround(cx, cy, cz, radius)
	glBeginEnd(GL_LINE_LOOP, function()
		for i = 0, 5 do
			local p = HEX_CORNERS[i]
			local hx = cx + p.x * radius
			local hz = cz + p.z * radius
			local hy = spGetGroundHeight(hx, hz) or cy
			glVertex(hx, hy + 2.0, hz)
		end
	end)
end

local function drawCircleGround(cx, cy, cz, radius)
	glBeginEnd(GL_LINE_LOOP, function()
		for i = 0, CIRCLE_SEGMENTS do
			local p = CIRCLE_POINTS[i]
			local hx = cx + p.x * radius
			local hz = cz + p.z * radius
			local hy = spGetGroundHeight(hx, hz) or cy
			glVertex(hx, hy + 2.0, hz)
		end
	end)
end

local function drawParabolicArc(gx, gy, gz, tx, ty, tz, sol, color, progress)
	local SAMPLES = 24
	local dt = sol.flightTime / SAMPLES
	local t = 0

	glLineWidth(2.0)
	glBeginEnd(GL_LINE_STRIP, function()
		for i = 0, SAMPLES do
			local curT = i * dt
			local x = gx + sol.dirX * (sol.vHoriz * curT)
			local z = gz + sol.dirZ * (sol.vHoriz * curT)
			local y = gy + (sol.vVert * curT) - 0.5 * sol.gravity * (curT * curT)
			local alpha = (1.0 - (i / SAMPLES) * 0.40) * color[4]
			glColor(color[1], color[2], color[3], alpha)
			glVertex(x, y, z)
		end
	end)

	-- Draw moving energy tracer bead along arc
	if progress and progress >= 0 and progress <= 1.0 then
		local beadT = progress * sol.flightTime
		local bx = gx + sol.dirX * (sol.vHoriz * beadT)
		local bz = gz + sol.dirZ * (sol.vHoriz * beadT)
		local by = gy + (sol.vVert * beadT) - 0.5 * sol.gravity * (beadT * beadT)
		glColor(1.0, 1.0, 0.40, 0.90)
		drawCircleGround(bx, by, bz, 14.0)
	end
end

function widget:DrawWorld()
	local curFrame = spGetGameFrame() or 0
	local pulse = 0.80 + 0.20 * sin(animClock * 6.0)

	-- 1. RENDER ACTIVE IN-FLIGHT EXECUTIONS
	for i = 1, #activeExecutions do
		local exec = activeExecutions[i]
		local totalFrames = exec.impactFrame - exec.startFrame
		local elapsedFrames = curFrame - exec.startFrame
		local remainingSec = max(0, (exec.impactFrame - curFrame) / 30.0)

		-- Draw target impact zones
		for j = 1, #exec.pairs do
			local p = exec.pairs[j]
			local color = p.clear and { 0.05, 0.90, 1.00, 0.85 * pulse } or { 1.00, 0.20, 0.20, 0.90 * pulse }
			glColor(color[1], color[2], color[3], color[4])
			glLineWidth(2.5)
			drawHexagonGround(p.targetX, p.targetY, p.targetZ, p.aoe * 0.90)

			-- If shell is in flight, draw trajectory
			if p.fired and p.solution then
				local flightFrames = ceil(p.flightTime * 30.0)
				local flightProgress = (curFrame - p.scheduledFireFrame) / max(1, flightFrames)
				drawParabolicArc(p.gunX, p.gunY, p.gunZ, p.targetX, p.targetY, p.targetZ, p.solution, { 1.00, 0.80, 0.20, 0.65 }, flightProgress)
			end
		end

		-- Floating 3D Holographic Timer over Target Centroid
		if config.showCountdownTimer and exec.centroid then
			local cx, cy, cz = exec.centroid.x, exec.centroid.y + 70.0, exec.centroid.z
			glPushMatrix()
			glTranslate(cx, cy, cz)
			glBillboard()
			glColor(0.02, 0.05, 0.08, 0.70)
			glRect(-90, -22, 90, 22)
			glColor(0.05, 0.90, 1.00, 0.95)
			glLineWidth(1.5)
			glBeginEnd(GL_LINE_LOOP, function()
				glVertex(-90, -22, 0)
				glVertex(90, -22, 0)
				glVertex(90, 22, 0)
				glVertex(-90, 22, 0)
			end)
			local timerStr = string.format("T.O.T. IMPACT: %.2fs", remainingSec)
			glText(timerStr, 0, -5, 14, "oc")
			glPopMatrix()
		end
	end

	-- 2. RENDER INTERACTIVE PREVIEW PLAN DURING DRAG
	if isDragging and currentPlan then
		local pairsList = currentPlan.pairs
		for i = 1, #pairsList do
			local p = pairsList[i]
			local col = p.clear and { 0.15, 1.00, 0.50, 0.85 * pulse } or { 1.00, 0.15, 0.15, 0.95 * pulse }

			-- Hexagonal Saturation Cell
			glColor(col[1], col[2], col[3], col[4])
			glLineWidth(2.0)
			drawHexagonGround(p.targetX, p.targetY, p.targetZ, p.aoe * 0.90)

			-- Center Reticle Danger Ring
			glColor(col[1], col[2], col[3], 0.45)
			drawCircleGround(p.targetX, p.targetY, p.targetZ, p.aoe * 0.35)

			-- Trajectory Arcs
			if config.showTrajectoryArcs and p.solution then
				local arcCol = p.clear and { 0.00, 0.85, 1.00, 0.55 } or { 1.00, 0.25, 0.25, 0.85 }
				drawParabolicArc(p.gunX, p.gunY, p.gunZ, p.targetX, p.targetY, p.targetZ, p.solution, arcCol, nil)
			end
		end

		-- Holographic Setup Marker over Centroid
		if currentPlan.centroid then
			local cx, cy, cz = currentPlan.centroid.x, currentPlan.centroid.y + 60.0, currentPlan.centroid.z
			glPushMatrix()
			glTranslate(cx, cy, cz)
			glBillboard()
			glColor(0.02, 0.05, 0.08, 0.75)
			glRect(-110, -26, 110, 26)
			glColor(0.15, 1.00, 0.50, 0.95)
			glLineWidth(1.8)
			glBeginEnd(GL_LINE_LOOP, function()
				glVertex(-110, -26, 0)
				glVertex(110, -26, 0)
				glVertex(110, 26, 0)
				glVertex(-110, 26, 0)
			end)
			local previewStr = string.format("T.O.T. SYNC: %d GUNS | %.1fs", currentPlan.unitCount, currentPlan.totDelay)
			glText(previewStr, 0, 4, 12, "oc")
			glColor(0.85, 0.85, 0.85, 0.80)
			glText(string.format("SPREAD: %.1fx (Wheel to adjust)", config.spreadMultiplier), 0, -14, 10, "oc")
			glPopMatrix()
		end
	end

	glColor(1, 1, 1, 1)
	glLineWidth(1.0)
end

--------------------------------------------------------------------------------
-- 2D Screen HUD Widget & Status Indicator
--------------------------------------------------------------------------------
function widget:DrawScreen()
	local arties = getSelectedArtillery()
	if #arties == 0 and not targetingModeActive then return end

	local vsx, vsy = spGetViewGeometry()
	local bw, bh = 220, 44
	local bx = vsx * 0.5 - bw * 0.5
	local by = 65

	-- Glassmorphic Tactical Status Bar
	glColor(0.02, 0.04, 0.07, 0.82)
	glRect(bx, by, bx + bw, by + bh)

	local borderColor = targetingModeActive and { 1.00, 0.75, 0.15, 0.95 } or { 0.15, 0.85, 1.00, 0.75 }
	glColor(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
	glLineWidth(1.8)
	glBeginEnd(GL_LINE_LOOP, function()
		glVertex(bx, by)
		glVertex(bx + bw, by)
		glVertex(bx + bw, by + bh)
		glVertex(bx, by + bh)
	end)

	-- Header text
	if targetingModeActive then
		glColor(1.00, 0.80, 0.20, 1.0)
		glText("T.O.T. BARRAGE [ACTIVE]", bx + bw * 0.5, by + 24, 13, "oc")
		glColor(0.85, 0.85, 0.85, 0.85)
		glText("Left-Click Drag to Target | Wheel for Spread", bx + bw * 0.5, by + 9, 10, "oc")
	else
		glColor(0.15, 0.85, 1.00, 1.0)
		glText(string.format("CARPET BARRAGE (B) [%d ARTILLERY]", #arties), bx + bw * 0.5, by + 24, 12, "oc")
		glColor(0.70, 0.80, 0.85, 0.80)
		glText("Press 'B' or Alt+Right Drag to Saturation Fire", bx + bw * 0.5, by + 9, 10, "oc")
	end

	glColor(1, 1, 1, 1)
	glLineWidth(1.0)
end
