local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Military Formation Move",
		desc = "Tactical military formation movement (Box, Circle) with coherent lateral projection matching and zero-GC batched rendering.",
		author = "Codex (refactored for AAA performance)",
		date = "2026.09",
		license = "GNU GPL, v2 or later",
		layer = 250,
		enabled = true,
		handler = true,
	}
end

--------------------------------------------------------------------------------
-- Constants & Configuration
--------------------------------------------------------------------------------
local CMD_MOVE = CMD.MOVE or 10
local CMD_PATROL = CMD.PATROL or 15
local CMD_FIGHT = CMD.FIGHT or 16
local CMD_RAW_MOVE = (CMD.RAW_MOVE) or 39812

local FORMATION_TYPES = {
	{ id = "box",    name = "Box",    desc = "Multi-rank rectangular phalanx grid formation" },
	{ id = "circle", name = "Circle", desc = "360-degree outward perimeter defense" },
}

local DEFAULT_SPACING = 30.0
local MIN_SPACING = 24.0
local MAX_SPACING = 150.0
local DRAG_MIN_DIST = 10.0

local GL_LINES = (GL and GL.LINES) or 0x0001
local GL_TRIANGLES = (GL and GL.TRIANGLES) or 0x0004
local GL_LINE_LOOP = (GL and GL.LINE_LOOP) or 0x0002
local GL_SRC_ALPHA = (GL and GL.SRC_ALPHA) or 0x0302
local GL_ONE_MINUS_SRC_ALPHA = (GL and GL.ONE_MINUS_SRC_ALPHA) or 0x0303

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local customModeEnabled = true
local isDragging = false
local isPatrolMode = false
local modeNotificationTime = 0
local modeNotificationText = ""
local modeNotificationColor = { 0.20, 1.00, 0.45 }

local dragStart = { x = 0, y = 0, z = 0 }
local dragCurrent = { x = 0, y = 0, z = 0 }
local selectedUnits = {}
local formationIndex = 1 -- 1: Box, 2: Circle
local currentSlots = {}
local unitSlotPairs = {}
local formationAnimTime = 0
local toggleFeedbackTimer = 0

local config = {
	customModeEnabled = true,
	defaultSpacing = 30.0,
	soundEnabled = true,
	drawLines = true,
	drawGhostRings = true,
}

local function toggleFormationMode()
	customModeEnabled = not customModeEnabled
	config.customModeEnabled = customModeEnabled
	toggleFeedbackTimer = 1.2
	if config.soundEnabled then
		Spring.PlaySoundFile("beep4", customModeEnabled and 0.90 or 0.40, "ui")
	end
end

--------------------------------------------------------------------------------
-- Math & Precalculated Trigonometry
--------------------------------------------------------------------------------
local sin, cos, atan2, sqrt, max, min, floor, ceil, pi = math.sin, math.cos, math.atan2, math.sqrt, math.max, math.min, math.floor, math.ceil, math.pi
local TWO_PI = pi * 2

local TEARDROP_SEGMENTS = 16
local TEARDROP_TRIG = {}
do
	for i = 0, TEARDROP_SEGMENTS do
		local frac = i / TEARDROP_SEGMENTS
		TEARDROP_TRIG[i] = frac
	end
end

local function getGroundHeight(x, z)
	return (Spring.GetGroundHeight(x, z) or 0)
end

local function clamp(v, low, high)
	return max(low, min(high, v))
end

local function normalize(dx, dz)
	local len = sqrt(dx * dx + dz * dz)
	if len < 1e-4 then
		return 0, 1, 0
	end
	return dx / len, dz / len, len
end

-- Filter out immobile units/buildings; only return units that can move
local function getMovableSelectedUnits()
	local allSelected = Spring.GetSelectedUnits() or {}
	local movable = {}
	for i = 1, #allSelected do
		local uid = allSelected[i]
		local defID = Spring.GetUnitDefID(uid)
		local ud = defID and UnitDefs[defID]
		if ud and ud.speed and ud.speed > 0.1 and not ud.isImmobile and not ud.isBuilding then
			movable[#movable + 1] = uid
		end
	end
	return movable
end

local function getSelectedUnitsMaxRadius(units)
	local maxRad = 18.0
	for i = 1, #units do
		local uid = units[i]
		local defID = Spring.GetUnitDefID(uid)
		local ud = defID and UnitDefs[defID]
		if ud then
			local rad = ud.radius or (max(ud.xsize or 2, ud.zsize or 2) * 8)
			if rad > maxRad then maxRad = rad end
		end
	end
	return maxRad
end

--------------------------------------------------------------------------------
-- Formation Slot Calculations (Line, Box, Wedge, Column, Circle)
--------------------------------------------------------------------------------
local function calculateFormationSlots(startX, startZ, endX, endZ, units, formIdx)
	local unitCount = type(units) == "table" and #units or (tonumber(units) or 0)
	if unitCount <= 0 then return {} end

	local dx = endX - startX
	local dz = endZ - startZ
	local fx, fz, dragDist = normalize(dx, dz)

	if dragDist < DRAG_MIN_DIST then
		local avgX, avgZ, count = 0, 0, 0
		if type(units) == "table" and #units > 0 then
			for i = 1, #units do
				local ux, _, uz = Spring.GetUnitPosition(units[i])
				if ux and uz then
					avgX = avgX + ux
					avgZ = avgZ + uz
					count = count + 1
				end
			end
		end

		if count > 0 then
			avgX = avgX / count
			avgZ = avgZ / count
			local marchDx = startX - avgX
			local marchDz = startZ - avgZ
			local mfx, mfz, marchDist = normalize(marchDx, marchDz)
			if marchDist > 5.0 then
				fx, fz = mfx, mfz
			else
				fx, fz = 0, -1
			end
		else
			fx, fz = 0, -1
		end
		dragDist = 0
	end

	-- Perpendicular right vector: r = (-fz, fx)
	local rx, rz = -fz, fx

	local maxUnitRadius = (type(units) == "table") and getSelectedUnitsMaxRadius(units) or 18.0
	local baseSpacing = max(config.defaultSpacing, maxUnitRadius * 1.40)
	local spacing = baseSpacing

	if dragDist > DRAG_MIN_DIST then
		if formIdx == 1 then -- Box
			local cols = ceil(sqrt(unitCount))
			spacing = clamp(dragDist / max(1, cols - 1), MIN_SPACING, MAX_SPACING)
		elseif formIdx == 2 then -- Circle
			spacing = clamp((dragDist * TWO_PI) / max(1, unitCount), MIN_SPACING, MAX_SPACING)
		end
	end

	local slots = {}
	local facingAngle = atan2(fx, fz)

	if formIdx == 1 then
		-- 1: BOX / PHALANX FORMATION (สี่เหลี่ยมกองร้อย)
		local cols = ceil(sqrt(unitCount))
		local rows = ceil(unitCount / cols)
		local halfCols = (cols - 1) * 0.5
		local halfRows = (rows - 1) * 0.5
		local colSpacing = spacing * 1.10
		local rowSpacing = spacing * 1.05
		local slotIdx = 1

		for r = 0, rows - 1 do
			for c = 0, cols - 1 do
				if slotIdx <= unitCount then
					local colOffset = (c - halfCols) * colSpacing
					local rowOffset = -(r - halfRows) * rowSpacing
					local sx = startX + rx * colOffset + fx * rowOffset
					local sz = startZ + rz * colOffset + fz * rowOffset
					slots[slotIdx] = {
						x = sx,
						y = getGroundHeight(sx, sz) + 2.0,
						z = sz,
						facing = facingAngle,
					}
					slotIdx = slotIdx + 1
				end
			end
		end

	elseif formIdx == 2 then
		-- 2: CIRCLE / PERIMETER DEFENSE (วงแหวนป้องกัน 360°)
		local radius = max(38.0, (unitCount * spacing) / TWO_PI)
		local angleStep = TWO_PI / unitCount
		for i = 1, unitCount do
			local a = (i - 1) * angleStep + facingAngle
			local sx = startX + sin(a) * radius
			local sz = startZ + cos(a) * radius
			slots[i] = {
				x = sx,
				y = getGroundHeight(sx, sz) + 2.0,
				z = sz,
				facing = a,
			}
		end
	end

	return slots
end

--------------------------------------------------------------------------------
-- Unit Range Hierarchy & Coherent Lateral Projection Matching (O(N log N))
--------------------------------------------------------------------------------
local function getUnitTacticalRange(uid)
	local defID = Spring.GetUnitDefID(uid)
	local ud = defID and UnitDefs[defID]
	if not ud then return 300.0 end

	if ud.isBuilder or ud.isBuilding or (ud.buildSpeed and ud.buildSpeed > 0 and (not ud.maxWeaponRange or ud.maxWeaponRange <= 0)) then
		return 99999.0
	end

	local maxRange = ud.maxWeaponRange or 0
	if maxRange <= 0 and ud.weapons and #ud.weapons > 0 then
		for w = 1, #ud.weapons do
			local wdefID = ud.weapons[w].weaponDef
			local wd = wdefID and WeaponDefs[wdefID]
			if wd and wd.range and wd.range > maxRange then
				maxRange = wd.range
			end
		end
	end

	return maxRange
end

-- Mathematically rigorous Coherent Lateral Projection (Zero Path Crossing)
local function matchUnitsToSlots(units, slots, facingAngle)
	if #units == 0 or #slots == 0 then return {} end
	local n = min(#units, #slots)

	facingAngle = facingAngle or (slots[1] and slots[1].facing) or 0
	local fx = sin(facingAngle)
	local fz = cos(facingAngle)
	local rx = -fz
	local rz = fx

	-- Tier 1: Vanguard (< 350 range)
	-- Tier 2: Skirmish (350..650 range)
	-- Tier 3: Rearguard (>= 650 range, artillery, builders)
	local uTiers = { {}, {}, {} }
	for i = 1, #units do
		local uid = units[i]
		local ux, uy, uz = Spring.GetUnitPosition(uid)
		local range = getUnitTacticalRange(uid)
		local tier = 2
		if range < 350 then
			tier = 1
		elseif range >= 650 then
			tier = 3
		end
		uTiers[tier][#uTiers[tier] + 1] = {
			id = uid,
			x = ux or 0,
			y = uy or 0,
			z = uz or 0,
			lat = (ux or 0) * rx + (uz or 0) * rz,
		}
	end

	-- Sort all slots by depth along forward vector (DESCENDING: front slots first)
	local slotList = {}
	for j = 1, #slots do
		local s = slots[j]
		local depth = s.x * fx + s.z * fz
		local lat = s.x * rx + s.z * rz
		slotList[j] = {
			slot = s,
			depth = depth,
			lat = lat,
		}
	end
	table.sort(slotList, function(a, b) return a.depth > b.depth end)

	-- Assign slots per tier and sort laterally to guarantee zero path crossing
	local pairsResult = {}
	local slotStartIdx = 1

	for tier = 1, 3 do
		local tierUnits = uTiers[tier]
		local tCount = #tierUnits
		if tCount > 0 then
			local tSlots = {}
			for s = slotStartIdx, min(#slotList, slotStartIdx + tCount - 1) do
				tSlots[#tSlots + 1] = slotList[s]
			end
			slotStartIdx = slotStartIdx + tCount

			table.sort(tierUnits, function(a, b) return a.lat < b.lat end)
			table.sort(tSlots, function(a, b) return a.lat < b.lat end)

			local matchCount = min(#tierUnits, #tSlots)
			for k = 1, matchCount do
				local u = tierUnits[k]
				local s = tSlots[k].slot
				pairsResult[#pairsResult + 1] = {
					unitID = u.id,
					unitX = u.x,
					unitY = u.y,
					unitZ = u.z,
					slot = s,
				}
			end
		end
	end

	return pairsResult
end

--------------------------------------------------------------------------------
-- Mouse Raycast & Input Capture (Non-blocking context sensitivity)
--------------------------------------------------------------------------------
local function getGroundFromMouse(mx, my)
	local _, pos = Spring.TraceScreenRay(mx, my, true, false, false)
	if pos then
		return pos[1], pos[2], pos[3]
	end
	return nil, nil, nil
end

function widget:MousePress(mx, my, button)
	if Spring.IsGUIHidden and Spring.IsGUIHidden() then return false end

	-- Do not interfere with building placement
	if Spring.GetActiveCommand then
		local _, cmdID = Spring.GetActiveCommand()
		if cmdID and cmdID < 0 then return false end
	end

	local _, _, meta, shift = Spring.GetModKeyState()

	-- Button 2 (Middle Click): Direct Instant Toggle ON / OFF (or Toggle Patrol if dragging)
	if button == 2 then
		if isDragging then
			-- Middle click while dragging toggles Patrol mode
			isPatrolMode = not isPatrolMode
			if config.soundEnabled then
				Spring.PlaySoundFile("beep4", isPatrolMode and 0.75 or 0.45, "ui")
			end
			return true
		end

		toggleFormationMode()
		return true
	end

	-- Button 3 (Right Click): Move Units
	if button == 3 then
		if customModeEnabled then
			-- Check raycast target under mouse cursor
			local traceType, targetID = Spring.TraceScreenRay(mx, my, false, false, false)

			-- NEVER intercept if clicking on a feature (Reclaiming wrecks / rocks / trees)
			if traceType == "feature" then
				return false
			end

			-- NEVER intercept if clicking on a unit:
			-- (Hostile -> attack; Allied -> assist / repair / guard / load)
			if traceType == "unit" and targetID then
				return false
			end

			local movables = getMovableSelectedUnits()
			if #movables > 0 then
				local gx, gy, gz = getGroundFromMouse(mx, my)
				if gx then
					isDragging = true
					isPatrolMode = false
					selectedUnits = movables
					dragStart = { x = gx, y = gy, z = gz }
					dragCurrent = { x = gx, y = gy, z = gz }
					currentSlots = calculateFormationSlots(gx, gz, gx, gz, selectedUnits, formationIndex)
					unitSlotPairs = matchUnitsToSlots(selectedUnits, currentSlots, 0)
					formationAnimTime = 0
					if config.soundEnabled then
						Spring.PlaySoundFile("beep4", 0.40, "ui")
					end
					return true
				end
			end
		end
	end

	return false
end

function widget:MouseMove(mx, my, dx, dy, button)
	if not isDragging then return false end

	local gx, gy, gz = getGroundFromMouse(mx, my)
	if gx then
		dragCurrent.x = gx
		dragCurrent.y = gy
		dragCurrent.z = gz
		local fdx = dragCurrent.x - dragStart.x
		local fdz = dragCurrent.z - dragStart.z
		local facingAngle = atan2(fdx, fdz)
		currentSlots = calculateFormationSlots(dragStart.x, dragStart.z, dragCurrent.x, dragCurrent.z, selectedUnits, formationIndex)
		unitSlotPairs = matchUnitsToSlots(selectedUnits, currentSlots, facingAngle)
	end
	return true
end

function widget:MouseWheel(up, value)
	local isUp = up or (value and value > 0)
	local _, _, meta, shift = Spring.GetModKeyState()

	if isDragging then
		if isUp then
			formationIndex = formationIndex + 1
			if formationIndex > #FORMATION_TYPES then formationIndex = 1 end
		else
			formationIndex = formationIndex - 1
			if formationIndex < 1 then formationIndex = #FORMATION_TYPES end
		end
		local fdx = dragCurrent.x - dragStart.x
		local fdz = dragCurrent.z - dragStart.z
		local facingAngle = atan2(fdx, fdz)
		currentSlots = calculateFormationSlots(dragStart.x, dragStart.z, dragCurrent.x, dragCurrent.z, selectedUnits, formationIndex)
		unitSlotPairs = matchUnitsToSlots(selectedUnits, currentSlots, facingAngle)

		modeNotificationTime = 1.4
		modeNotificationText = "FORMATION: " .. string.upper(FORMATION_TYPES[formationIndex].name)
		modeNotificationColor = isPatrolMode and { 0.15, 0.72, 1.00 } or { 0.20, 1.00, 0.45 }

		if config.soundEnabled then
			Spring.PlaySoundFile("beep4", 0.60, "ui")
		end
		return true
	elseif customModeEnabled and (meta or shift) then
		if isUp then
			formationIndex = formationIndex + 1
			if formationIndex > #FORMATION_TYPES then formationIndex = 1 end
		else
			formationIndex = formationIndex - 1
			if formationIndex < 1 then formationIndex = #FORMATION_TYPES end
		end

		modeNotificationTime = 1.4
		modeNotificationText = "FORMATION: " .. string.upper(FORMATION_TYPES[formationIndex].name)
		modeNotificationColor = { 0.20, 1.00, 0.45 }

		if config.soundEnabled then
			Spring.PlaySoundFile("beep4", 0.60, "ui")
		end
		return true
	end
	return false
end

function widget:MouseRelease(mx, my, button)
	if isDragging and (button == 3 or button == 2) then
		isDragging = false
		local _, _, _, shift = Spring.GetModKeyState()
		local cmdOptions = shift and { "shift" } or {}
		local orderCMD = isPatrolMode and CMD_PATROL or CMD_MOVE

		if #unitSlotPairs > 0 then
			local ddx = dragCurrent.x - dragStart.x
			local ddz = dragCurrent.z - dragStart.z
			local dragDist = sqrt(ddx * ddx + ddz * ddz)

			-- If barely dragged (< 10 elmos), issue standard group move to clicked point
			if dragDist < DRAG_MIN_DIST then
				for i = 1, #selectedUnits do
					Spring.GiveOrderToUnit(selectedUnits[i], orderCMD, { dragStart.x, dragStart.y, dragStart.z }, cmdOptions)
				end
			else
				-- Formations dispatched!
				for i = 1, #unitSlotPairs do
					local pair = unitSlotPairs[i]
					local s = pair.slot
					if pair.unitID and s then
						Spring.GiveOrderToUnit(pair.unitID, orderCMD, { s.x, s.y, s.z }, cmdOptions)
					end
				end
			end
			if config.soundEnabled then
				Spring.PlaySoundFile("beep4", 0.75, "ui")
			end
		end

		isPatrolMode = false
		currentSlots = {}
		unitSlotPairs = {}
		selectedUnits = {}
		return true
	end

	return false
end

function widget:Update(dt)
	if isDragging then
		formationAnimTime = formationAnimTime + dt
	end
	if modeNotificationTime > 0 then
		modeNotificationTime = max(0, modeNotificationTime - dt)
	end
	if toggleFeedbackTimer > 0 then
		toggleFeedbackTimer = max(0, toggleFeedbackTimer - dt)
	end
end

function widget:KeyPress(key, mods, isRepeat)
	if isRepeat then return false end
	-- Alt + F shortcut to toggle
	if mods and mods.alt and (key == 102 or key == 70) then
		toggleFormationMode()
		return true
	end
	return false
end

function widget:TextCommand(cmd)
	if cmd == "formation" or cmd == "form" then
		toggleFormationMode()
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Batched Zero-GC 3D Rendering Pipeline
--------------------------------------------------------------------------------
local function emitTeardropTriangles(cx, cy, cz, facing, radius, tipLength, rCore, gCore, bCore, aCore, rEdge, gEdge, bEdge, aEdge)
	local fx, fz = sin(facing), cos(facing)
	local rx, rz = -fz, fx
	local ratio = clamp(radius / tipLength, 0.2, 0.8)
	local alphaAngle = math.asin(ratio)

	local tipX = cx + fx * tipLength
	local tipZ = cz + fz * tipLength
	local tipY = cy

	local startAngle = alphaAngle
	local endAngle = -pi - alphaAngle
	local totalSweep = endAngle - startAngle

	local a0 = startAngle
	local prevX = cx + rx * (radius * cos(a0)) + fx * (radius * sin(a0))
	local prevZ = cz + rz * (radius * cos(a0)) + fz * (radius * sin(a0))

	-- Right tangent triangle to Tip
	gl.Color(rCore, gCore, bCore, aCore)
	gl.Vertex(cx, cy, cz)
	gl.Color(rEdge, gEdge, bEdge, aEdge)
	gl.Vertex(prevX, cy, prevZ)
	gl.Vertex(tipX, tipY, tipZ)

	-- Sweep fan
	for i = 1, TEARDROP_SEGMENTS do
		local a = startAngle + TEARDROP_TRIG[i] * totalSweep
		local currX = cx + rx * (radius * cos(a)) + fx * (radius * sin(a))
		local currZ = cz + rz * (radius * cos(a)) + fz * (radius * sin(a))

		gl.Color(rCore, gCore, bCore, aCore)
		gl.Vertex(cx, cy, cz)
		gl.Color(rEdge, gEdge, bEdge, aEdge)
		gl.Vertex(prevX, cy, prevZ)
		gl.Vertex(currX, cy, currZ)

		prevX, prevZ = currX, currZ
	end

	-- Left tangent triangle to Tip
	gl.Color(rCore, gCore, bCore, aCore)
	gl.Vertex(cx, cy, cz)
	gl.Color(rEdge, gEdge, bEdge, aEdge)
	gl.Vertex(prevX, cy, prevZ)
	gl.Vertex(tipX, tipY, tipZ)
end

local function emitTeardropLines(cx, cy, cz, facing, radius, tipLength)
	local fx, fz = sin(facing), cos(facing)
	local rx, rz = -fz, fx
	local ratio = clamp(radius / tipLength, 0.2, 0.8)
	local alphaAngle = math.asin(ratio)

	local tipX = cx + fx * tipLength
	local tipZ = cz + fz * tipLength
	local tipY = cy + 0.2

	local startAngle = alphaAngle
	local endAngle = -pi - alphaAngle
	local totalSweep = endAngle - startAngle

	local a0 = startAngle
	local prevX = cx + rx * (radius * cos(a0)) + fx * (radius * sin(a0))
	local prevZ = cz + rz * (radius * cos(a0)) + fz * (radius * sin(a0))

	gl.Vertex(tipX, tipY, tipZ)
	gl.Vertex(prevX, cy + 0.2, prevZ)

	for i = 1, TEARDROP_SEGMENTS do
		local a = startAngle + TEARDROP_TRIG[i] * totalSweep
		local currX = cx + rx * (radius * cos(a)) + fx * (radius * sin(a))
		local currZ = cz + rz * (radius * cos(a)) + fz * (radius * sin(a))

		gl.Vertex(prevX, cy + 0.2, prevZ)
		gl.Vertex(currX, cy + 0.2, currZ)

		prevX, prevZ = currX, currZ
	end

	gl.Vertex(prevX, cy + 0.2, prevZ)
	gl.Vertex(tipX, tipY, tipZ)
end

function widget:DrawWorld()
	if not isDragging or #currentSlots == 0 then return end
	if Spring.IsGUIHidden and Spring.IsGUIHidden() then return end

	gl.DepthTest(true)
	if gl.DepthMask then gl.DepthMask(false) end
	if gl.PolygonOffset then gl.PolygonOffset(-30, -30) end
	gl.Blending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

	local pulse = 0.75 + 0.25 * sin(formationAnimTime * 8.0)

	local dx = dragCurrent.x - dragStart.x
	local dz = dragCurrent.z - dragStart.z
	local fx, fz = normalize(dx, dz)
	local masterFacing = atan2(fx, fz)

	-- 1. Single Batched Pass: Unit to Slot trajectory lines
	if config.drawLines and #unitSlotPairs > 0 then
		local lr = isPatrolMode and 0.15 or 0.20
		local lg = isPatrolMode and 0.72 or 0.95
		local lb = isPatrolMode and 1.00 or 0.45
		gl.LineWidth(2.0)
		gl.Color(lr, lg, lb, 0.45 * pulse)
		gl.BeginEnd(GL_LINES, function()
			for i = 1, #unitSlotPairs do
				local pair = unitSlotPairs[i]
				local s = pair.slot
				if s and pair.unitX then
					gl.Vertex(pair.unitX, pair.unitY + 4.0, pair.unitZ)
					gl.Vertex(s.x, s.y + 1.2, s.z)
				end
			end
		end)
		gl.LineWidth(1.0)
	end

	-- 2. Single Batched Pass: Holographic Destination Teardrops
	if config.drawGhostRings then
		local rCore, gCore, bCore, aCore
		local rEdge, gEdge, bEdge, aEdge
		local rNeon, gNeon, bNeon, aNeon

		if isPatrolMode then
			rCore, gCore, bCore, aCore = 0.15, 0.72, 1.00, 0.72 * pulse
			rEdge, gEdge, bEdge, aEdge = 0.05, 0.35, 0.85, 0.12 * pulse
			rNeon, gNeon, bNeon, aNeon = 0.30, 0.88, 1.00, 0.95 * pulse
		else
			rCore, gCore, bCore, aCore = 0.20, 1.00, 0.45, 0.68 * pulse
			rEdge, gEdge, bEdge, aEdge = 0.05, 0.80, 0.25, 0.10 * pulse
			rNeon, gNeon, bNeon, aNeon = 0.35, 1.00, 0.55, 0.95 * pulse
		end

		-- Pass A: All Filled Triangles Batched
		gl.BeginEnd(GL_TRIANGLES, function()
			for i = 1, #currentSlots do
				local s = currentSlots[i]
				emitTeardropTriangles(s.x, s.y, s.z, s.facing or masterFacing, 9.0, 17.0, rCore, gCore, bCore, aCore, rEdge, gEdge, bEdge, aEdge)
			end
		end)

		-- Pass B: Sharp Luminous Outlines Batched
		gl.LineWidth(2.0)
		gl.Color(rNeon, gNeon, bNeon, aNeon)
		gl.BeginEnd(GL_LINES, function()
			for i = 1, #currentSlots do
				local s = currentSlots[i]
				emitTeardropLines(s.x, s.y, s.z, s.facing or masterFacing, 9.0, 17.0)
			end
		end)
		gl.LineWidth(1.0)
	end

	gl.Color(1, 1, 1, 1)
	if gl.PolygonOffset then gl.PolygonOffset(0, 0) end
	if gl.DepthMask then gl.DepthMask(true) end
	gl.DepthTest(false)
	gl.Blending(false)
end

function widget:DrawScreen()
	if Spring.IsGUIHidden and Spring.IsGUIHidden() then return end

	local mx, my = Spring.GetMouseState()
	if not mx or not my then return end

	-- Tactical Cursor Micro-Badge (แสดงตัวย่อยเล็กๆ ข้างลูกศรตลอดเวลาที่เปิดโหมด)
	if customModeEnabled then
		local formName = string.upper(FORMATION_TYPES[formationIndex].name)
		local badgeText = "FORM: " .. formName
		local rText, gText, bText = 0.22, 1.00, 0.48

		if isDragging then
			local uCount = #selectedUnits
			if isPatrolMode then
				badgeText = "PATROL: " .. formName .. " (" .. uCount .. ")"
				rText, gText, bText = 0.20, 0.85, 1.00
			else
				badgeText = "FORM: " .. formName .. " (" .. uCount .. ")"
				rText, gText, bText = 0.25, 1.00, 0.50
			end
		end

		local bx = mx + 18
		local by = my - 12
		local fontSize = 10
		local padX = 5
		local padY = 3
		local textW = fontSize * (#badgeText * 0.54)
		local bw = textW + padX * 2
		local bh = fontSize + padY * 2

		-- Translucent glass background pill
		gl.Color(0.02, 0.05, 0.08, 0.82)
		gl.Rect(bx, by - bh, bx + bw, by)

		-- Subtle glowing accent border
		gl.LineWidth(1.0)
		gl.Color(rText, gText, bText, 0.70)
		gl.BeginEnd(GL_LINE_LOOP, function()
			gl.Vertex(bx, by - bh, 0)
			gl.Vertex(bx + bw, by - bh, 0)
			gl.Vertex(bx + bw, by, 0)
			gl.Vertex(bx, by, 0)
		end)

		-- Badge text
		gl.Color(rText, gText, bText, 0.95)
		gl.Text(badgeText, bx + padX, by - bh + padY, fontSize, "on")
	elseif toggleFeedbackTimer > 0 then
		-- Brief subtle "OFF" indicator when just turned off
		local alpha = min(1.0, toggleFeedbackTimer / 0.3)
		local bx = mx + 18
		local by = my - 12
		local fontSize = 10
		local badgeText = "FORM: OFF"
		local padX = 5
		local padY = 3
		local textW = fontSize * (#badgeText * 0.54)
		local bw = textW + padX * 2
		local bh = fontSize + padY * 2

		gl.Color(0.02, 0.05, 0.08, 0.82 * alpha)
		gl.Rect(bx, by - bh, bx + bw, by)

		gl.LineWidth(1.0)
		gl.Color(0.95, 0.30, 0.30, 0.70 * alpha)
		gl.BeginEnd(GL_LINE_LOOP, function()
			gl.Vertex(bx, by - bh, 0)
			gl.Vertex(bx + bw, by - bh, 0)
			gl.Vertex(bx + bw, by, 0)
			gl.Vertex(bx, by, 0)
		end)

		gl.Color(0.95, 0.30, 0.30, 0.95 * alpha)
		gl.Text(badgeText, bx + padX, by - bh + padY, fontSize, "on")
	end

	gl.Color(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- Options Registration
--------------------------------------------------------------------------------
function widget:Initialize()
	customModeEnabled = (config.customModeEnabled ~= false)
	if WG['options'] and WG['options'].addOptions then
		WG['options'].addOptions({
			{
				id = "military_formation__sound",
				widgetname = "Military Formation Move",
				name = "Sound Feedback",
				description = "Play tactical audio chimes when creating and dispatching formations.",
				type = "bool",
				value = config.soundEnabled,
				onchange = function(_, v) config.soundEnabled = v end,
			},
			{
				id = "military_formation__lines",
				widgetname = "Military Formation Move",
				name = "Connecting Path Lines",
				description = "Draw tactical trajectory lines from units to their assigned formation slots.",
				type = "bool",
				value = config.drawLines,
				onchange = function(_, v) config.drawLines = v end,
			},
		})
	end
end

function widget:Shutdown()
	isDragging = false
	currentSlots = {}
	unitSlotPairs = {}
	selectedUnits = {}
end

function widget:GetConfigData()
	config.customModeEnabled = customModeEnabled
	return config
end

function widget:SetConfigData(data)
	if type(data) == "table" then
		for k, v in pairs(data) do
			if config[k] ~= nil then config[k] = v end
		end
		if config.customModeEnabled ~= nil then
			customModeEnabled = config.customModeEnabled
		end
	end
end
