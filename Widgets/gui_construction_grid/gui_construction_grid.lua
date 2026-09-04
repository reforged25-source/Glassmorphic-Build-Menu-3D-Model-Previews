local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Build Grid 2.0",
		desc = "Orange ground footprints for all finished units & structures with white rounded placement grid, active only in build mode. (v2.0 by reforged25-source)",
		author = "reforged25-source / Codex",
		version = "2.0",
		date = "2026 (v2.0)",
		license = "GNU GPL, v2 or later",
		layer = 180,
		enabled = true,
		handler = true,
	}
end

--------------------------------------------------------------------------------
-- Construction Base Grid & Unit Footprint Overlays (GL4 Engine Edition)
--------------------------------------------------------------------------------

local CONST = {
	GRID_CELL_SIZE = 8,
	MAJOR_EVERY = 4,
	MAJOR_STEP = 32,
	BLOCK_INSET = 2.0,
	BLOCK_CORNER_RADIUS = 4.5,
	BLOCK_ARC_SEGMENTS = 6,

	COLORED_CELL_STEP = 16,
	COLORED_CELL_SCALE = 0.5,
	COLORED_CELL_INSET = 1.0,
	COLORED_CELL_CORNER_RADIUS = 2.25,
	COLORED_CELL_NATIVE_SPAN = 2,
	INNER_DIVIDER_ALPHA = 0.68,
	INNER_DIVIDER_GAP = 3.5,
	COLORED_INNER_DIVIDER_GAP = 1.75,

	OCCUPIED_FILL_ALPHA = 0.75,
	OCCUPIED_FILL_OFFSET = 1.8,
	STATUS_OCCUPIED = 1,
	BUILT_UNIT_FILL_ALPHA = 0.70,
	BUILT_UNIT_FILL_OFFSET = 1.6,
	QUEUED_FILL_ALPHA = 0.68,
	QUEUED_FILL_OFFSET = 1.4,

	QUEUE_REFRESH_SECONDS = 1.0,
	QUEUE_COMMAND_SCAN_LIMIT = 1200,
	QUEUE_API_RECHECK_SECONDS = 1.0,

	ENGINE_SQUARE_SIZE = 8,
	GRID_RADIUS = 400,
	TERRAIN_SEGMENT = 16,
	GROUND_OFFSET = 0.65,
	EDGE_EPSILON = 0.002,

	MAP_SIZE_X = (Game and Game.mapSizeX) or 8192,
	MAP_SIZE_Z = (Game and Game.mapSizeZ) or 8192,
	MAX_INITIAL_FILL_INSTANCES = 128,
}

local GL_ENUMS = {
	LINES = (GL and GL.LINES) or 0x0001,
	TRIANGLES = (GL and GL.TRIANGLES) or 0x0004,
	SRC_ALPHA = (GL and GL.SRC_ALPHA) or 0x0302,
	ONE_MINUS_SRC_ALPHA = (GL and GL.ONE_MINUS_SRC_ALPHA) or 0x0303,
	ARRAY_BUFFER = (GL and GL.ARRAY_BUFFER) or 0x8892,
	ELEMENT_ARRAY_BUFFER = (GL and GL.ELEMENT_ARRAY_BUFFER) or 0x8893,
	UNSIGNED_SHORT = (GL and GL.UNSIGNED_SHORT) or 0x1403,
}

local State = {
	enabled = true,
	myTeamID = nil,
	finishedUnits = {},
	trackedBuilders = {},
	queuedBuilds = {},
	queueRefreshElapsed = 0,
	queueRefreshPending = true,
	queueAPIRecheckElapsed = 0,
	buildModeWasActive = false,

	-- Display lists fallback
	roundedGridList = nil,
	roundedGridListX = nil,
	roundedGridListZ = nil,
	roundedGridListAlignmentX = nil,
	roundedGridListAlignmentZ = nil,
	roundedGridDirty = true,
	finishedGroundList = nil,
	finishedGroundDirty = true,
	queuedGroundList = nil,
	queuedGroundDirty = true,
	builderQueueAPI = nil,
	builderQueueCallbacks = {},
	usingBuilderQueueAPI = false,

	-- GL4 White Grid
	gridShader = nil,
	gridCenterUniform = nil,
	gridBaseAlphaUniform = nil,
	gridGL4Ready = false,
	gridOuterStaticMesh = nil,
	gridInnerStaticMesh = nil,
	gridStaticVariants = {},

	-- GL4 Footprint Fills
	fillShader = nil,
	fillHeightOffsetUniform = nil,
	fillColorUniform = nil,
	fillCellInsetUniform = nil,
	fillCornerRadiusUniform = nil,
	fillGL4Ready = false,
	fillQuadVBO = nil,
	fillQuadIndexVBO = nil,
	fillIndexCount = 0,
	fillBatches = {},

	-- State caching
	lastOccupiedUnitDefID = nil,
	lastOccupiedX = nil,
	lastOccupiedZ = nil,
	lastOccupiedFacing = nil,
	lastOccupiedStatusHash = nil,

	-- Scratch buffers
	occupiedFillScratch = {},
	queuedFillScratch = {},
	finishedFillScratch = {},
	partialBlocksScratch = {},

	-- Latest active build unit for grid rendering
	activeBuildSquare = nil,
}

-- Precalculated angular offsets for rounded corners
local ARC_OFFSETS = {}
do
	local pi = math.pi
	local starts = {-pi * 0.5, 0, pi * 0.5, pi}
	for arcIndex = 1, 4 do
		local points = {}
		local startAngle = starts[arcIndex]
		local endAngle = startAngle + pi * 0.5
		for segment = 0, CONST.BLOCK_ARC_SEGMENTS do
			local angle = startAngle + (endAngle - startAngle) * (segment / CONST.BLOCK_ARC_SEGMENTS)
			points[segment + 1] = {math.cos(angle), math.sin(angle)}
		end
		ARC_OFFSETS[arcIndex] = points
	end
end

local M = {}

function M.getUnitXZ(unitID)
	if not unitID then return nil, nil end
	local ux, _, uz = Spring.GetUnitPosition(unitID)
	return ux, uz
end

function M.isBuildModeActive()
	if not Spring.GetActiveCommand then return false end
	local _, commandID = Spring.GetActiveCommand()
	if type(commandID) ~= "number" or commandID >= 0 then return false end
	local buildDef = UnitDefs[-commandID]
	return buildDef ~= nil
end

function M.clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

function M.groundY(x, z)
	return (Spring.GetGroundHeight(x, z) or 0) + CONST.GROUND_OFFSET
end

function M.coloredGroundY(x, z, offset)
	return (Spring.GetGroundHeight(x, z) or 0) + offset
end

function M.radialAlpha(baseAlpha, x, z, centerX, centerZ, radius)
	local dx = x - centerX
	local dz = z - centerZ
	local normalized = math.sqrt(dx * dx + dz * dz) / radius
	local fade = 1 - M.clamp(normalized, 0, 1)
	return baseAlpha * fade * fade
end

function M.emitTerrainSegmentAtHeights(x0, y0, z0, x1, y1, z1, centerX, centerZ, radius, baseAlpha)
	local midX = (x0 + x1) * 0.5
	local midZ = (z0 + z1) * 0.5
	local alpha = M.radialAlpha(baseAlpha, midX, midZ, centerX, centerZ, radius)
	if alpha <= CONST.EDGE_EPSILON then return end

	gl.Color(1, 1, 1, alpha)
	gl.Vertex(x0, y0, z0)
	gl.Vertex(x1, y1, z1)
end

function M.emitTerrainSegment(x0, z0, x1, z1, centerX, centerZ, radius, baseAlpha)
	M.emitTerrainSegmentAtHeights(
		x0, M.groundY(x0, z0), z0,
		x1, M.groundY(x1, z1), z1,
		centerX, centerZ, radius, baseAlpha
	)
end

function M.emitArcSegment(cx, cz, cornerRadius, arcIndex, centerX, centerZ, radius)
	local offsets = ARC_OFFSETS[arcIndex]
	local previousX = cx + offsets[1][1] * cornerRadius
	local previousZ = cz + offsets[1][2] * cornerRadius
	local previousY = M.groundY(previousX, previousZ)
	for pointIndex = 2, #offsets do
		local offset = offsets[pointIndex]
		local nextX = cx + offset[1] * cornerRadius
		local nextZ = cz + offset[2] * cornerRadius
		local nextY = M.groundY(nextX, nextZ)
		M.emitTerrainSegmentAtHeights(
			previousX, previousY, previousZ,
			nextX, nextY, nextZ,
			centerX, centerZ, radius, 0.96
		)
		previousX, previousY, previousZ = nextX, nextY, nextZ
	end
end

function M.emitRoundedBlock(blockX, blockZ, centerX, centerZ, radius)
	local x0 = math.max(0, blockX + CONST.COLORED_CELL_INSET)
	local z0 = math.max(0, blockZ + CONST.COLORED_CELL_INSET)
	local x1 = math.min(CONST.MAP_SIZE_X, blockX + CONST.COLORED_CELL_STEP - CONST.COLORED_CELL_INSET)
	local z1 = math.min(CONST.MAP_SIZE_Z, blockZ + CONST.COLORED_CELL_STEP - CONST.COLORED_CELL_INSET)
	if x1 <= x0 or z1 <= z0 then return end

	local cornerRadius = math.min(CONST.COLORED_CELL_CORNER_RADIUS, (x1 - x0) * 0.5, (z1 - z0) * 0.5)

	M.emitTerrainSegment(x0 + cornerRadius, z0, x1 - cornerRadius, z0, centerX, centerZ, radius, 0.96)
	M.emitTerrainSegment(x1 - cornerRadius, z1, x0 + cornerRadius, z1, centerX, centerZ, radius, 0.96)
	M.emitTerrainSegment(x0, z1 - cornerRadius, x0, z0 + cornerRadius, centerX, centerZ, radius, 0.96)
	M.emitTerrainSegment(x1, z0 + cornerRadius, x1, z1 - cornerRadius, centerX, centerZ, radius, 0.96)

	M.emitArcSegment(x1 - cornerRadius, z0 + cornerRadius, cornerRadius, 1, centerX, centerZ, radius)
	M.emitArcSegment(x1 - cornerRadius, z1 - cornerRadius, cornerRadius, 2, centerX, centerZ, radius)
	M.emitArcSegment(x0 + cornerRadius, z1 - cornerRadius, cornerRadius, 3, centerX, centerZ, radius)
	M.emitArcSegment(x0 + cornerRadius, z0 + cornerRadius, cornerRadius, 4, centerX, centerZ, radius)
end

function M.emitInnerDividers(blockX, blockZ, centerX, centerZ, radius)
	local x0 = math.max(0, blockX + CONST.COLORED_CELL_INSET + CONST.COLORED_INNER_DIVIDER_GAP)
	local z0 = math.max(0, blockZ + CONST.COLORED_CELL_INSET + CONST.COLORED_INNER_DIVIDER_GAP)
	local x1 = math.min(CONST.MAP_SIZE_X, blockX + CONST.COLORED_CELL_STEP - CONST.COLORED_CELL_INSET - CONST.COLORED_INNER_DIVIDER_GAP)
	local z1 = math.min(CONST.MAP_SIZE_Z, blockZ + CONST.COLORED_CELL_STEP - CONST.COLORED_CELL_INSET - CONST.COLORED_INNER_DIVIDER_GAP)
	if x1 <= x0 or z1 <= z0 then return end

	local middleX = (x0 + x1) * 0.5
	local middleZ = (z0 + z1) * 0.5
	M.emitTerrainSegment(middleX, z0, middleX, z1, centerX, centerZ, radius, CONST.INNER_DIVIDER_ALPHA)
	M.emitTerrainSegment(x0, middleZ, x1, middleZ, centerX, centerZ, radius, CONST.INNER_DIVIDER_ALPHA)
end

function M.drawRoundedGrid(centerX, centerZ, radius, alignmentX, alignmentZ)
	alignmentX = alignmentX or 0
	alignmentZ = alignmentZ or 0
	local xStart = math.floor((centerX - radius - alignmentX) / CONST.COLORED_CELL_STEP) * CONST.COLORED_CELL_STEP + alignmentX
	local xEnd = math.ceil((centerX + radius - alignmentX) / CONST.COLORED_CELL_STEP) * CONST.COLORED_CELL_STEP + alignmentX
	local zStart = math.floor((centerZ - radius - alignmentZ) / CONST.COLORED_CELL_STEP) * CONST.COLORED_CELL_STEP + alignmentZ
	local zEnd = math.ceil((centerZ + radius - alignmentZ) / CONST.COLORED_CELL_STEP) * CONST.COLORED_CELL_STEP + alignmentZ
	local expandedRadius = radius + CONST.COLORED_CELL_STEP
	local expandedRadiusSquared = expandedRadius * expandedRadius
	local visibleBlockCount = 0

	for blockX = xStart, xEnd, CONST.COLORED_CELL_STEP do
		for blockZ = zStart, zEnd, CONST.COLORED_CELL_STEP do
			local dx = blockX + CONST.COLORED_CELL_STEP * 0.5 - centerX
			local dz = blockZ + CONST.COLORED_CELL_STEP * 0.5 - centerZ
			if dx * dx + dz * dz <= expandedRadiusSquared then
				visibleBlockCount = visibleBlockCount + 1
				local index = visibleBlockCount * 2
				State.partialBlocksScratch[index - 1] = blockX
				State.partialBlocksScratch[index] = blockZ
			end
		end
	end

	gl.LineWidth(2.2)
	gl.BeginEnd(GL_ENUMS.LINES, function()
		for blockIndex = 1, visibleBlockCount do
			local index = blockIndex * 2
			M.emitRoundedBlock(State.partialBlocksScratch[index - 1], State.partialBlocksScratch[index], centerX, centerZ, radius)
		end
	end)

	gl.LineWidth(1.35)
	gl.BeginEnd(GL_ENUMS.LINES, function()
		for blockIndex = 1, visibleBlockCount do
			local index = blockIndex * 2
			M.emitInnerDividers(State.partialBlocksScratch[index - 1], State.partialBlocksScratch[index], centerX, centerZ, radius)
		end
	end)
end

--------------------------------------------------------------------------------
-- GPU White Grid Shader & Meshes
--------------------------------------------------------------------------------

local GRID_VERTEX_SHADER = [[
#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

layout (location = 0) in vec2 cellVertex;
layout (location = 1) in vec2 cellOriginOffset;

//__ENGINEUNIFORMBUFFERDEFS__

out vec2 worldXZ;
out float lineAlpha;

uniform sampler2D heightmapTex;
uniform vec2 gridCenter;
uniform float heightOffset;
uniform float gridRadius;
uniform float baseAlpha;

vec2 heightmapUVatWorldPos(vec2 worldpos) {
	vec2 inverseMapSize = vec2(1.0) / mapSize.xy;
	vec2 heightmaptexel = vec2(8.0, 8.0);
	worldpos += vec2(-8.0, -8.0) * (worldpos * inverseMapSize) + vec2(4.0, 4.0);
	vec2 uvhm = clamp(worldpos, heightmaptexel, mapSize.xy - heightmaptexel);
	return uvhm * inverseMapSize;
}

void main() {
	worldXZ = gridCenter + cellOriginOffset + cellVertex;
	vec2 sampledXZ = clamp(worldXZ, vec2(0.0), mapSize.xy);
	vec2 uvhm = heightmapUVatWorldPos(sampledXZ);
	float worldY = textureLod(heightmapTex, uvhm, 0.0).x + heightOffset;
	float normalizedDistance = clamp(distance(worldXZ, gridCenter) / gridRadius, 0.0, 1.0);
	float fade = 1.0 - normalizedDistance;
	lineAlpha = baseAlpha * fade * fade;
	gl_Position = cameraViewProj * vec4(worldXZ.x, worldY, worldXZ.y, 1.0);
}
]]

local GRID_FRAGMENT_SHADER = [[
#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

//__ENGINEUNIFORMBUFFERDEFS__

in vec2 worldXZ;
in float lineAlpha;
out vec4 fragColor;

void main() {
	if (worldXZ.x < 0.0 || worldXZ.y < 0.0 || worldXZ.x > mapSize.x || worldXZ.y > mapSize.y) {
		discard;
	}
	if (lineAlpha <= 0.002) {
		discard;
	}
	fragColor = vec4(1.0, 1.0, 1.0, lineAlpha);
}
]]

function M.appendStaticLine(data, x0, z0, x1, z1)
	local index = #data
	data[index + 1] = x0
	data[index + 2] = z0
	data[index + 3] = x1
	data[index + 4] = z1
end

function M.createStaticGridMesh(data)
	if #data == 0 then return nil end
	local vertexCount = #data / 2
	local vbo = gl.GetVBO(GL_ENUMS.ARRAY_BUFFER, false)
	local indexVBO = gl.GetVBO(GL_ENUMS.ELEMENT_ARRAY_BUFFER, false)
	if not vbo or not indexVBO then
		if vbo then vbo:Delete() end
		if indexVBO then indexVBO:Delete() end
		return nil
	end
	vbo:Define(vertexCount, {{id = 0, name = "cellVertex", size = 2}})
	vbo:Upload(data)
	local indices = {}
	for index = 0, vertexCount - 1 do
		indices[index + 1] = index
	end
	indexVBO:Define(vertexCount, GL_ENUMS.UNSIGNED_SHORT)
	indexVBO:Upload(indices)
	return {vbo = vbo, indexVBO = indexVBO, indexCount = vertexCount}
end

function M.deleteStaticGridMesh(mesh)
	if not mesh then return end
	if mesh.indexVBO then mesh.indexVBO:Delete() end
	if mesh.vbo then mesh.vbo:Delete() end
end

function M.initializeStaticGridMeshes()
	local outerData = {}
	local innerData = {}
	local x0 = CONST.COLORED_CELL_INSET
	local z0 = CONST.COLORED_CELL_INSET
	local x1 = CONST.COLORED_CELL_STEP - CONST.COLORED_CELL_INSET
	local z1 = CONST.COLORED_CELL_STEP - CONST.COLORED_CELL_INSET
	local cornerRadius = CONST.COLORED_CELL_CORNER_RADIUS

	M.appendStaticLine(outerData, x0 + cornerRadius, z0, x1 - cornerRadius, z0)
	M.appendStaticLine(outerData, x1 - cornerRadius, z1, x0 + cornerRadius, z1)
	M.appendStaticLine(outerData, x0, z1 - cornerRadius, x0, z0 + cornerRadius)
	M.appendStaticLine(outerData, x1, z0 + cornerRadius, x1, z1 - cornerRadius)

	local centers = {
		{x1 - cornerRadius, z0 + cornerRadius},
		{x1 - cornerRadius, z1 - cornerRadius},
		{x0 + cornerRadius, z1 - cornerRadius},
		{x0 + cornerRadius, z0 + cornerRadius},
	}
	for arcIndex = 1, 4 do
		local cx = centers[arcIndex][1]
		local cz = centers[arcIndex][2]
		local offsets = ARC_OFFSETS[arcIndex]
		local previousX = cx + offsets[1][1] * cornerRadius
		local previousZ = cz + offsets[1][2] * cornerRadius
		for pointIndex = 2, #offsets do
			local offset = offsets[pointIndex]
			local nextX = cx + offset[1] * cornerRadius
			local nextZ = cz + offset[2] * cornerRadius
			M.appendStaticLine(outerData, previousX, previousZ, nextX, nextZ)
			previousX, previousZ = nextX, nextZ
		end
	end

	local dividerX0 = x0 + CONST.COLORED_INNER_DIVIDER_GAP
	local dividerZ0 = z0 + CONST.COLORED_INNER_DIVIDER_GAP
	local dividerX1 = x1 - CONST.COLORED_INNER_DIVIDER_GAP
	local dividerZ1 = z1 - CONST.COLORED_INNER_DIVIDER_GAP
	local middleX = (dividerX0 + dividerX1) * 0.5
	local middleZ = (dividerZ0 + dividerZ1) * 0.5
	M.appendStaticLine(innerData, middleX, dividerZ0, middleX, dividerZ1)
	M.appendStaticLine(innerData, dividerX0, middleZ, dividerX1, middleZ)

	State.gridOuterStaticMesh = M.createStaticGridMesh(outerData)
	State.gridInnerStaticMesh = M.createStaticGridMesh(innerData)
	return State.gridOuterStaticMesh ~= nil and State.gridInnerStaticMesh ~= nil
end

function M.deleteGridVariant(variant)
	if not variant then return end
	if variant.outerVAO then variant.outerVAO:Delete() end
	if variant.innerVAO then variant.innerVAO:Delete() end
	if variant.instanceVBO then variant.instanceVBO:Delete() end
end

function M.createGridVariant(alignmentOffsetX, alignmentOffsetZ)
	local instanceData = {}
	local instanceCount = 0
	local xStart = math.floor((-CONST.GRID_RADIUS - alignmentOffsetX) / CONST.COLORED_CELL_STEP) * CONST.COLORED_CELL_STEP + alignmentOffsetX
	local xEnd = math.ceil((CONST.GRID_RADIUS - alignmentOffsetX) / CONST.COLORED_CELL_STEP) * CONST.COLORED_CELL_STEP + alignmentOffsetX
	local zStart = math.floor((-CONST.GRID_RADIUS - alignmentOffsetZ) / CONST.COLORED_CELL_STEP) * CONST.COLORED_CELL_STEP + alignmentOffsetZ
	local zEnd = math.ceil((CONST.GRID_RADIUS - alignmentOffsetZ) / CONST.COLORED_CELL_STEP) * CONST.COLORED_CELL_STEP + alignmentOffsetZ
	local expandedRadius = CONST.GRID_RADIUS + CONST.COLORED_CELL_STEP
	local expandedRadiusSquared = expandedRadius * expandedRadius

	for blockX = xStart, xEnd, CONST.COLORED_CELL_STEP do
		for blockZ = zStart, zEnd, CONST.COLORED_CELL_STEP do
			local dx = blockX + CONST.COLORED_CELL_STEP * 0.5
			local dz = blockZ + CONST.COLORED_CELL_STEP * 0.5
			if dx * dx + dz * dz <= expandedRadiusSquared then
				instanceCount = instanceCount + 1
				local index = instanceCount * 2
				instanceData[index - 1] = blockX
				instanceData[index] = blockZ
			end
		end
	end
	if instanceCount == 0 then return nil end

	local instanceVBO = gl.GetVBO(GL_ENUMS.ARRAY_BUFFER, true)
	if not instanceVBO then return nil end
	instanceVBO:Define(instanceCount, {{id = 1, name = "cellOriginOffset", size = 2}})
	instanceVBO:Upload(instanceData)

	local outerVAO = gl.GetVAO()
	local innerVAO = gl.GetVAO()
	if not outerVAO or not innerVAO then
		if outerVAO then outerVAO:Delete() end
		if innerVAO then innerVAO:Delete() end
		instanceVBO:Delete()
		return nil
	end
	outerVAO:AttachVertexBuffer(State.gridOuterStaticMesh.vbo)
	outerVAO:AttachInstanceBuffer(instanceVBO)
	outerVAO:AttachIndexBuffer(State.gridOuterStaticMesh.indexVBO)
	innerVAO:AttachVertexBuffer(State.gridInnerStaticMesh.vbo)
	innerVAO:AttachInstanceBuffer(instanceVBO)
	innerVAO:AttachIndexBuffer(State.gridInnerStaticMesh.indexVBO)
	return {
		instanceVBO = instanceVBO,
		outerVAO = outerVAO,
		innerVAO = innerVAO,
		instanceCount = instanceCount,
	}
end

function M.initializeStaticVariants()
	State.gridStaticVariants[0] = {}
	State.gridStaticVariants[8] = {}

	State.gridStaticVariants[0][0] = M.createGridVariant(0, 0)
	State.gridStaticVariants[8][0] = M.createGridVariant(8, 0)
	State.gridStaticVariants[0][8] = M.createGridVariant(0, 8)
	State.gridStaticVariants[8][8] = M.createGridVariant(8, 8)

	return State.gridStaticVariants[0][0] and State.gridStaticVariants[8][0]
		and State.gridStaticVariants[0][8] and State.gridStaticVariants[8][8]
end

function M.getGridVariant(centerX, centerZ, alignmentX, alignmentZ)
	local ox = math.floor((alignmentX - centerX) % CONST.COLORED_CELL_STEP + 0.5)
	if ox < 0 then ox = ox + CONST.COLORED_CELL_STEP end
	local oz = math.floor((alignmentZ - centerZ) % CONST.COLORED_CELL_STEP + 0.5)
	if oz < 0 then oz = oz + CONST.COLORED_CELL_STEP end

	ox = (ox >= 4 and ox < 12) and 8 or 0
	oz = (oz >= 4 and oz < 12) and 8 or 0

	local row = State.gridStaticVariants[ox]
	return row and row[oz]
end

function M.getEngineUniformBufferDefs()
	local uboMatDefs = (gl.GetEngineUniformBufferDef and gl.GetEngineUniformBufferDef(0)) or ""
	local uboParamDefs = (gl.GetEngineUniformBufferDef and gl.GetEngineUniformBufferDef(1)) or ""
	local combined = uboMatDefs .. "\n" .. uboParamDefs
	if #combined > 2 then
		return combined
	end
	if gl.LuaShader and type(gl.LuaShader.GetEngineUniformBufferDefs) == "function" then
		return gl.LuaShader.GetEngineUniformBufferDefs() or ""
	end
	return ""
end

function M.initializeGridGL4()
	if not gl.LuaShader or not gl.GetVBO or not gl.GetVAO or not gl.Texture
		or not gl.GetUniformLocation or not gl.Uniform or not GL_ENUMS.ARRAY_BUFFER
		or not GL_ENUMS.ELEMENT_ARRAY_BUFFER or not GL_ENUMS.UNSIGNED_SHORT
	then
		return false
	end
	local engineUniforms = M.getEngineUniformBufferDefs()
	local vertexSource = GRID_VERTEX_SHADER:gsub("//__ENGINEUNIFORMBUFFERDEFS__", engineUniforms)
	local fragmentSource = GRID_FRAGMENT_SHADER:gsub("//__ENGINEUNIFORMBUFFERDEFS__", engineUniforms)
	State.gridShader = gl.LuaShader({
		vertex = vertexSource,
		fragment = fragmentSource,
		uniformInt = {heightmapTex = 0},
		uniformFloat = {
			gridCenter = {0, 0},
			heightOffset = CONST.GROUND_OFFSET,
			gridRadius = CONST.GRID_RADIUS,
			baseAlpha = 0.96,
		},
	}, "Build Grid 2.0")
	if not State.gridShader or not State.gridShader:Initialize() then
		State.gridShader = nil
		return false
	end
	if not M.initializeStaticGridMeshes() then
		M.deleteStaticGridMesh(State.gridOuterStaticMesh)
		M.deleteStaticGridMesh(State.gridInnerStaticMesh)
		State.gridOuterStaticMesh = nil
		State.gridInnerStaticMesh = nil
		if type(State.gridShader.Finalize) == "function" then State.gridShader:Finalize() end
		State.gridShader = nil
		return false
	end
	if not M.initializeStaticVariants() then
		M.deleteStaticGridMesh(State.gridOuterStaticMesh)
		M.deleteStaticGridMesh(State.gridInnerStaticMesh)
		State.gridOuterStaticMesh = nil
		State.gridInnerStaticMesh = nil
		if type(State.gridShader.Finalize) == "function" then State.gridShader:Finalize() end
		State.gridShader = nil
		return false
	end
	State.gridCenterUniform = gl.GetUniformLocation(State.gridShader.shaderObj, "gridCenter")
	State.gridBaseAlphaUniform = gl.GetUniformLocation(State.gridShader.shaderObj, "baseAlpha")
	State.gridGL4Ready = State.gridCenterUniform ~= nil and State.gridBaseAlphaUniform ~= nil
	return State.gridGL4Ready
end

function M.drawRoundedGridGL4(centerX, centerZ, alignmentX, alignmentZ)
	if not State.gridGL4Ready then return false end
	local variant = M.getGridVariant(centerX, centerZ, alignmentX, alignmentZ)
	if not variant then return false end
	gl.Texture(0, "$heightmap")
	State.gridShader:Activate()
	gl.Uniform(State.gridCenterUniform, centerX, centerZ)
	gl.Uniform(State.gridBaseAlphaUniform, 0.96)
	variant.outerVAO:DrawElements(
		GL_ENUMS.LINES, State.gridOuterStaticMesh.indexCount, 0, variant.instanceCount
	)
	gl.Uniform(State.gridBaseAlphaUniform, CONST.INNER_DIVIDER_ALPHA)
	variant.innerVAO:DrawElements(
		GL_ENUMS.LINES, State.gridInnerStaticMesh.indexCount, 0, variant.instanceCount
	)
	State.gridShader:Deactivate()
	gl.Texture(0, false)
	return true
end

function M.freeGridGL4()
	for _, row in pairs(State.gridStaticVariants) do
		for _, variant in pairs(row) do
			M.deleteGridVariant(variant)
		end
	end
	State.gridStaticVariants = {}
	M.deleteStaticGridMesh(State.gridOuterStaticMesh)
	M.deleteStaticGridMesh(State.gridInnerStaticMesh)
	State.gridOuterStaticMesh = nil
	State.gridInnerStaticMesh = nil
	if State.gridShader and type(State.gridShader.Finalize) == "function" then
		State.gridShader:Finalize()
	end
	State.gridShader = nil
	State.gridGL4Ready = false
end

--------------------------------------------------------------------------------
-- GPU Rounded Footprint Fills
--------------------------------------------------------------------------------

local FILL_VERTEX_SHADER = [[
#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

layout (location = 0) in vec2 quadCorner;
layout (location = 1) in vec4 tileData;

//__ENGINEUNIFORMBUFFERDEFS__

out vec2 worldXZ;
out vec2 localPosition;
flat out vec2 tileSpan;

uniform sampler2D heightmapTex;
uniform float heightOffset;

vec2 heightmapUVatWorldPos(vec2 worldpos) {
	vec2 inverseMapSize = vec2(1.0) / mapSize.xy;
	vec2 heightmaptexel = vec2(8.0, 8.0);
	worldpos += vec2(-8.0, -8.0) * (worldpos * inverseMapSize) + vec2(4.0, 4.0);
	vec2 uvhm = clamp(worldpos, heightmaptexel, mapSize.xy - heightmaptexel);
	return uvhm * inverseMapSize;
}

void main() {
	tileSpan = tileData.zw;
	localPosition = quadCorner * tileSpan;
	worldXZ = tileData.xy + localPosition;
	vec2 sampledXZ = clamp(worldXZ, vec2(0.0), mapSize.xy);
	vec2 uvhm = heightmapUVatWorldPos(sampledXZ);
	float worldY = textureLod(heightmapTex, uvhm, 0.0).x + heightOffset;
	gl_Position = cameraViewProj * vec4(worldXZ.x, worldY, worldXZ.y, 1.0);
}
]]

local FILL_FRAGMENT_SHADER = [[
#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

//__ENGINEUNIFORMBUFFERDEFS__

in vec2 worldXZ;
in vec2 localPosition;
flat in vec2 tileSpan;
out vec4 fragColor;

uniform vec4 fillColor;
uniform float cellInset;
uniform float cornerRadius;

void main() {
	if (worldXZ.x < 0.0 || worldXZ.y < 0.0 || worldXZ.x > mapSize.x || worldXZ.y > mapSize.y) {
		discard;
	}
	vec2 innerMin = vec2(cellInset);
	vec2 innerMax = tileSpan - vec2(cellInset);
	vec2 halfSize = max((innerMax - innerMin) * 0.5, vec2(0.001));
	vec2 center = (innerMin + innerMax) * 0.5;
	float radius = min(cornerRadius, min(halfSize.x, halfSize.y));
	vec2 q = abs(localPosition - center) - (halfSize - vec2(radius));
	float distanceToRoundedRect = length(max(q, vec2(0.0)))
		+ min(max(q.x, q.y), 0.0) - radius;
	float antialiasWidth = max(fwidth(distanceToRoundedRect), 0.35);
	float coverage = 1.0 - smoothstep(-antialiasWidth, antialiasWidth, distanceToRoundedRect);
	if (coverage <= 0.001) {
		discard;
	}
	fragColor = vec4(fillColor.rgb, fillColor.a * coverage);
}
]]

function M.deleteFillBatch(batchName)
	local batch = State.fillBatches[batchName]
	if not batch then return end
	if batch.vao then batch.vao:Delete() end
	if batch.instanceVBO then batch.instanceVBO:Delete() end
	State.fillBatches[batchName] = nil
end

function M.ensureFillBatch(batchName, requiredCount)
	local batch = State.fillBatches[batchName]
	if batch and requiredCount <= batch.capacity then
		return batch
	end
	if batch then M.deleteFillBatch(batchName) end

	local capacity = CONST.MAX_INITIAL_FILL_INSTANCES
	while capacity < requiredCount do
		capacity = capacity * 2
	end
	local instanceVBO = gl.GetVBO(GL_ENUMS.ARRAY_BUFFER, true)
	local vao = gl.GetVAO()
	if not instanceVBO or not vao then
		if instanceVBO then instanceVBO:Delete() end
		if vao then vao:Delete() end
		return nil
	end
	instanceVBO:Define(capacity, {{id = 1, name = "tileData", size = 4}})
	vao:AttachVertexBuffer(State.fillQuadVBO)
	vao:AttachInstanceBuffer(instanceVBO)
	vao:AttachIndexBuffer(State.fillQuadIndexVBO)
	batch = {
		instanceVBO = instanceVBO,
		vao = vao,
		capacity = capacity,
		count = 0,
	}
	State.fillBatches[batchName] = batch
	return batch
end

function M.uploadFillBatch(batchName, instanceData, instanceCount)
	if instanceCount <= 0 then
		local batch = State.fillBatches[batchName]
		if batch then batch.count = 0 end
		return true
	end
	local batch = M.ensureFillBatch(batchName, instanceCount)
	if not batch then return false end
	local totalFloats = instanceCount * 4
	local uploadData = instanceData
	if #instanceData > totalFloats then
		uploadData = {}
		for i = 1, totalFloats do
			uploadData[i] = instanceData[i]
		end
	end
	batch.instanceVBO:Upload(uploadData)
	batch.count = instanceCount
	return true
end

function M.drawFillBatch(batchName, red, green, blue, alpha, heightOffset)
	local batch = State.fillBatches[batchName]
	if not batch or batch.count <= 0 then return true end
	gl.Texture(0, "$heightmap")
	State.fillShader:Activate()
	gl.Uniform(State.fillHeightOffsetUniform, heightOffset)
	gl.Uniform(State.fillColorUniform, red, green, blue, alpha)
	if State.fillCellInsetUniform then gl.Uniform(State.fillCellInsetUniform, CONST.COLORED_CELL_INSET) end
	if State.fillCornerRadiusUniform then gl.Uniform(State.fillCornerRadiusUniform, CONST.COLORED_CELL_CORNER_RADIUS) end
	batch.vao:DrawElements(GL_ENUMS.TRIANGLES, State.fillIndexCount, 0, batch.count)
	State.fillShader:Deactivate()
	gl.Texture(0, false)
	return true
end

function M.initializeFillGL4()
	if not gl.LuaShader or not gl.GetVBO or not gl.GetVAO or not gl.Texture
		or not gl.GetUniformLocation or not gl.Uniform or not GL_ENUMS.ARRAY_BUFFER
		or not GL_ENUMS.ELEMENT_ARRAY_BUFFER or not GL_ENUMS.UNSIGNED_SHORT
	then
		return false
	end
	local engineUniforms = M.getEngineUniformBufferDefs()
	State.fillShader = gl.LuaShader({
		vertex = FILL_VERTEX_SHADER:gsub("//__ENGINEUNIFORMBUFFERDEFS__", engineUniforms),
		fragment = FILL_FRAGMENT_SHADER:gsub("//__ENGINEUNIFORMBUFFERDEFS__", engineUniforms),
		uniformInt = {heightmapTex = 0},
		uniformFloat = {
			heightOffset = CONST.QUEUED_FILL_OFFSET,
			fillColor = {1, 1, 1, 1},
			cellInset = CONST.COLORED_CELL_INSET,
			cornerRadius = CONST.COLORED_CELL_CORNER_RADIUS,
		},
	}, "Construction Grid Footprint Fills")
	if not State.fillShader or not State.fillShader:Initialize() then
		State.fillShader = nil
		return false
	end

	State.fillQuadVBO = gl.GetVBO(GL_ENUMS.ARRAY_BUFFER, false)
	State.fillQuadIndexVBO = gl.GetVBO(GL_ENUMS.ELEMENT_ARRAY_BUFFER, false)
	if not State.fillQuadVBO or not State.fillQuadIndexVBO then
		if State.fillQuadVBO then State.fillQuadVBO:Delete() end
		if State.fillQuadIndexVBO then State.fillQuadIndexVBO:Delete() end
		State.fillQuadVBO = nil
		State.fillQuadIndexVBO = nil
		if type(State.fillShader.Finalize) == "function" then State.fillShader:Finalize() end
		State.fillShader = nil
		return false
	end

	State.fillQuadVBO:Define(9, {{id = 0, name = "quadCorner", size = 2}})
	State.fillQuadVBO:Upload({
		0, 0,   0.5, 0,   1, 0,
		0, 0.5, 0.5, 0.5, 1, 0.5,
		0, 1,   0.5, 1,   1, 1,
	})
	local fillIndices = {
		0, 4, 1,   0, 3, 4,
		1, 5, 2,   1, 4, 5,
		3, 7, 4,   3, 6, 7,
		4, 8, 5,   4, 7, 8,
	}
	State.fillIndexCount = #fillIndices
	State.fillQuadIndexVBO:Define(State.fillIndexCount, GL_ENUMS.UNSIGNED_SHORT)
	State.fillQuadIndexVBO:Upload(fillIndices)

	State.fillHeightOffsetUniform = gl.GetUniformLocation(State.fillShader.shaderObj, "heightOffset")
	State.fillColorUniform = gl.GetUniformLocation(State.fillShader.shaderObj, "fillColor")
	State.fillCellInsetUniform = gl.GetUniformLocation(State.fillShader.shaderObj, "cellInset")
	State.fillCornerRadiusUniform = gl.GetUniformLocation(State.fillShader.shaderObj, "cornerRadius")
	State.fillGL4Ready = State.fillHeightOffsetUniform ~= nil and State.fillHeightOffsetUniform ~= -1
		and State.fillColorUniform ~= nil and State.fillColorUniform ~= -1
	return State.fillGL4Ready
end

function M.freeFillGL4()
	M.deleteFillBatch("occupied")
	M.deleteFillBatch("queued")
	M.deleteFillBatch("finished")
	if State.fillQuadIndexVBO then State.fillQuadIndexVBO:Delete() end
	if State.fillQuadVBO then State.fillQuadVBO:Delete() end
	State.fillQuadIndexVBO = nil
	State.fillQuadVBO = nil
	State.fillIndexCount = 0
	if State.fillShader and type(State.fillShader.Finalize) == "function" then
		State.fillShader:Finalize()
	end
	State.fillShader = nil
	State.fillHeightOffsetUniform = nil
	State.fillColorUniform = nil
	State.fillCellInsetUniform = nil
	State.fillCornerRadiusUniform = nil
	State.fillGL4Ready = false
	State.lastOccupiedUnitDefID = nil
	State.lastOccupiedX = nil
	State.lastOccupiedZ = nil
	State.lastOccupiedFacing = nil
	State.lastOccupiedStatusHash = nil
end

function M.appendFillInstance(instanceData, instanceCount, x, z, spanX, spanZ)
	instanceCount = instanceCount + 1
	local index = instanceCount * 4
	instanceData[index - 3] = x
	instanceData[index - 2] = z
	instanceData[index - 1] = spanX
	instanceData[index] = spanZ
	return instanceCount
end

function M.appendFootprintFillInstances(instanceData, instanceCount, unitDef, x, z, facing, statuses)
	facing = facing or 0
	local xsize = ((facing % 2) == 0) and unitDef.xsize or unitDef.zsize
	local zsize = ((facing % 2) == 1) and unitDef.xsize or unitDef.zsize
	if not xsize or not zsize then return instanceCount, 0 end

	local sx = math.floor(x / CONST.ENGINE_SQUARE_SIZE) - math.floor(xsize / 2)
	local sz = math.floor(z / CONST.ENGINE_SQUARE_SIZE) - math.floor(zsize / 2)
	local statusHash = 0
	if statuses then
		for cellIndex = 1, xsize * zsize do
			statusHash = (statusHash * 131 + (tonumber(statuses[cellIndex]) or 0) + 17) % 2147483647
		end
	end

	for zi = 0, zsize - 1, CONST.COLORED_CELL_NATIVE_SPAN do
		local nativeZEnd = math.min(zi + CONST.COLORED_CELL_NATIVE_SPAN - 1, zsize - 1)
		for xi = 0, xsize - 1, CONST.COLORED_CELL_NATIVE_SPAN do
			local nativeXEnd = math.min(xi + CONST.COLORED_CELL_NATIVE_SPAN - 1, xsize - 1)
			local shouldAdd = statuses == nil
			if statuses then
				for nativeZ = zi, nativeZEnd do
					for nativeX = xi, nativeXEnd do
						if statuses[nativeZ * xsize + nativeX + 1] == CONST.STATUS_OCCUPIED then
							shouldAdd = true
							break
						end
					end
					if shouldAdd then break end
				end
			end
			if shouldAdd then
				instanceCount = M.appendFillInstance(
					instanceData,
					instanceCount,
					(sx + xi) * CONST.ENGINE_SQUARE_SIZE,
					(sz + zi) * CONST.ENGINE_SQUARE_SIZE,
					(nativeXEnd - xi + 1) * CONST.ENGINE_SQUARE_SIZE,
					(nativeZEnd - zi + 1) * CONST.ENGINE_SQUARE_SIZE
				)
			end
		end
	end
	return instanceCount, statusHash
end

function M.drawOccupiedCellsGL4(unitDefID, x, z, facing, statuses)
	if not State.fillGL4Ready or type(statuses) ~= "table" then return false end
	local unitDef = UnitDefs[unitDefID]
	if not unitDef then return false end

	facing = facing or 0
	local instanceCount, statusHash = M.appendFootprintFillInstances(
		State.occupiedFillScratch, 0, unitDef, x, z, facing, statuses
	)

	if State.lastOccupiedUnitDefID ~= unitDefID
		or State.lastOccupiedX ~= x
		or State.lastOccupiedZ ~= z
		or State.lastOccupiedFacing ~= facing
		or State.lastOccupiedStatusHash ~= statusHash
	then
		if not M.uploadFillBatch("occupied", State.occupiedFillScratch, instanceCount) then return false end
		State.lastOccupiedUnitDefID = unitDefID
		State.lastOccupiedX = x
		State.lastOccupiedZ = z
		State.lastOccupiedFacing = facing
		State.lastOccupiedStatusHash = statusHash
	end

	M.drawFillBatch("occupied", 1.0, 0.08, 0.06, CONST.OCCUPIED_FILL_ALPHA, CONST.OCCUPIED_FILL_OFFSET)
	return true
end

function M.drawFootprintOutline(unitDefID, x, z, facing)
	local unitDef = UnitDefs[unitDefID]
	if not unitDef then return end
	facing = facing or 0

	local xsize = ((facing % 2) == 0) and unitDef.xsize or unitDef.zsize
	local zsize = ((facing % 2) == 1) and unitDef.xsize or unitDef.zsize
	if not xsize or not zsize then return end

	local sx = math.floor(x / CONST.ENGINE_SQUARE_SIZE) - math.floor(xsize / 2)
	local sz = math.floor(z / CONST.ENGINE_SQUARE_SIZE) - math.floor(zsize / 2)
	local x0 = sx * CONST.ENGINE_SQUARE_SIZE
	local z0 = sz * CONST.ENGINE_SQUARE_SIZE
	local x1 = (sx + xsize) * CONST.ENGINE_SQUARE_SIZE
	local z1 = (sz + zsize) * CONST.ENGINE_SQUARE_SIZE

	gl.LineWidth(2.0)
	gl.BeginEnd(GL_ENUMS.LINES, function()
		for px = x0, x1 - 0.001, CONST.TERRAIN_SEGMENT do
			local nx = math.min(px + CONST.TERRAIN_SEGMENT, x1)
			M.emitTerrainSegment(px, z0, nx, z0, x, z, CONST.GRID_RADIUS, 0.98)
			M.emitTerrainSegment(px, z1, nx, z1, x, z, CONST.GRID_RADIUS, 0.98)
		end
		for pz = z0, z1 - 0.001, CONST.TERRAIN_SEGMENT do
			local nz = math.min(pz + CONST.TERRAIN_SEGMENT, z1)
			M.emitTerrainSegment(x0, pz, x0, nz, x, z, CONST.GRID_RADIUS, 0.98)
			M.emitTerrainSegment(x1, pz, x1, nz, x, z, CONST.GRID_RADIUS, 0.98)
		end
	end)
end

function M.footprintGridAlignment(unitDefID, x, z, facing)
	local unitDef = UnitDefs[unitDefID]
	if not unitDef then return 0, 0 end
	facing = facing or 0
	local xsize = ((facing % 2) == 0) and unitDef.xsize or unitDef.zsize
	local zsize = ((facing % 2) == 1) and unitDef.xsize or unitDef.zsize
	if not xsize or not zsize then return 0, 0 end
	local sx = math.floor(x / CONST.ENGINE_SQUARE_SIZE) - math.floor(xsize / 2)
	local sz = math.floor(z / CONST.ENGINE_SQUARE_SIZE) - math.floor(zsize / 2)
	local ax = (sx * CONST.ENGINE_SQUARE_SIZE) % CONST.COLORED_CELL_STEP
	local az = (sz * CONST.ENGINE_SQUARE_SIZE) % CONST.COLORED_CELL_STEP
	if ax < 0 then ax = ax + CONST.COLORED_CELL_STEP end
	if az < 0 then az = az + CONST.COLORED_CELL_STEP end
	return ax, az
end

function M.emitFillTriangle(centerX, centerY, centerZ, ax, az, bx, bz, heightOffset)
	gl.Vertex(centerX, centerY, centerZ)
	gl.Vertex(ax, M.coloredGroundY(ax, az, heightOffset), az)
	gl.Vertex(bx, M.coloredGroundY(bx, bz, heightOffset), bz)
end

function M.emitFillArc(centerX, centerY, centerZ, cx, cz, cornerRadius, arcIndex, heightOffset)
	local offsets = ARC_OFFSETS[arcIndex]
	local previousX = cx + offsets[1][1] * cornerRadius
	local previousZ = cz + offsets[1][2] * cornerRadius
	local previousY = M.coloredGroundY(previousX, previousZ, heightOffset)
	for pointIndex = 2, #offsets do
		local offset = offsets[pointIndex]
		local nextX = cx + offset[1] * cornerRadius
		local nextZ = cz + offset[2] * cornerRadius
		local nextY = M.coloredGroundY(nextX, nextZ, heightOffset)
		gl.Vertex(centerX, centerY, centerZ)
		gl.Vertex(previousX, previousY, previousZ)
		gl.Vertex(nextX, nextY, nextZ)
		previousX, previousY, previousZ = nextX, nextY, nextZ
	end
end

function M.emitRoundedColorFill(x0, z0, x1, z1, heightOffset, cornerRadiusLimit)
	if x1 <= x0 or z1 <= z0 then return end
	local cornerRadius = math.min(cornerRadiusLimit or CONST.BLOCK_CORNER_RADIUS, (x1 - x0) * 0.5, (z1 - z0) * 0.5)
	local centerX = (x0 + x1) * 0.5
	local centerZ = (z0 + z1) * 0.5
	local centerY = M.coloredGroundY(centerX, centerZ, heightOffset)

	M.emitFillTriangle(centerX, centerY, centerZ, x0 + cornerRadius, z0, x1 - cornerRadius, z0, heightOffset)
	M.emitFillArc(centerX, centerY, centerZ, x1 - cornerRadius, z0 + cornerRadius, cornerRadius, 1, heightOffset)
	M.emitFillTriangle(centerX, centerY, centerZ, x1, z0 + cornerRadius, x1, z1 - cornerRadius, heightOffset)
	M.emitFillArc(centerX, centerY, centerZ, x1 - cornerRadius, z1 - cornerRadius, cornerRadius, 2, heightOffset)
	M.emitFillTriangle(centerX, centerY, centerZ, x1 - cornerRadius, z1, x0 + cornerRadius, z1, heightOffset)
	M.emitFillArc(centerX, centerY, centerZ, x0 + cornerRadius, z1 - cornerRadius, cornerRadius, 3, heightOffset)
	M.emitFillTriangle(centerX, centerY, centerZ, x0, z1 - cornerRadius, x0, z0 + cornerRadius, heightOffset)
	M.emitFillArc(centerX, centerY, centerZ, x0 + cornerRadius, z0 + cornerRadius, cornerRadius, 4, heightOffset)
end

function M.drawOccupiedCells(unitDefID, x, z, facing, statuses)
	if M.drawOccupiedCellsGL4(unitDefID, x, z, facing, statuses) then return end
	if type(statuses) ~= "table" then return end
	local unitDef = UnitDefs[unitDefID]
	if not unitDef then return end
	facing = facing or 0

	local xsize = ((facing % 2) == 0) and unitDef.xsize or unitDef.zsize
	local zsize = ((facing % 2) == 1) and unitDef.xsize or unitDef.zsize
	if not xsize or not zsize then return end

	local sx = math.floor(x / CONST.ENGINE_SQUARE_SIZE) - math.floor(xsize / 2)
	local sz = math.floor(z / CONST.ENGINE_SQUARE_SIZE) - math.floor(zsize / 2)
	gl.Color(1.0, 0.08, 0.06, CONST.OCCUPIED_FILL_ALPHA)
	gl.BeginEnd(GL_ENUMS.TRIANGLES, function()
		for zi = 0, zsize - 1, CONST.COLORED_CELL_NATIVE_SPAN do
			for xi = 0, xsize - 1, CONST.COLORED_CELL_NATIVE_SPAN do
				local occupied = false
				local nativeXEnd = math.min(xi + CONST.COLORED_CELL_NATIVE_SPAN - 1, xsize - 1)
				local nativeZEnd = math.min(zi + CONST.COLORED_CELL_NATIVE_SPAN - 1, zsize - 1)
				for nativeZ = zi, nativeZEnd do
					for nativeX = xi, nativeXEnd do
						local cellIndex = nativeZ * xsize + nativeX + 1
						if statuses[cellIndex] == CONST.STATUS_OCCUPIED then
							occupied = true
							break
						end
					end
					if occupied then break end
				end
				if occupied then
					local wx0 = (sx + xi) * CONST.ENGINE_SQUARE_SIZE + CONST.COLORED_CELL_INSET
					local wz0 = (sz + zi) * CONST.ENGINE_SQUARE_SIZE + CONST.COLORED_CELL_INSET
					local wx1 = (sx + nativeXEnd + 1) * CONST.ENGINE_SQUARE_SIZE - CONST.COLORED_CELL_INSET
					local wz1 = (sz + nativeZEnd + 1) * CONST.ENGINE_SQUARE_SIZE - CONST.COLORED_CELL_INSET
					M.emitRoundedColorFill(
						wx0, wz0, wx1, wz1,
						CONST.OCCUPIED_FILL_OFFSET,
						CONST.COLORED_CELL_CORNER_RADIUS
					)
				end
			end
		end
	end)
end

function M.unitIsFinished(unitID)
	if not Spring.GetUnitIsBeingBuilt then return true end
	local beingBuilt = Spring.GetUnitIsBeingBuilt(unitID)
	return beingBuilt ~= true
end

function M.unitFacing(unitID)
	local buildFacing = Spring.GetUnitBuildFacing and Spring.GetUnitBuildFacing(unitID)
	if type(buildFacing) == "number" then
		return math.floor(buildFacing + 0.5) % 4
	end
	local heading = Spring.GetUnitHeading and Spring.GetUnitHeading(unitID)
	if not heading then return 0 end
	return math.floor((heading % 65536 + 8192) / 16384) % 4
end

function M.isFriendlyUnit(unitID, unitTeam)
	if Spring.GetSpectatingFullView and Spring.GetSpectatingFullView() then
		return true
	end
	State.myTeamID = Spring.GetMyTeamID and Spring.GetMyTeamID()
	if not State.myTeamID or State.myTeamID < 0 then
		return true
	end
	unitTeam = unitTeam or (Spring.GetUnitTeam and Spring.GetUnitTeam(unitID))
	if unitTeam and unitTeam == State.myTeamID then
		return true
	end
	local myAllyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
	local unitAllyID = Spring.GetUnitAllyTeam and Spring.GetUnitAllyTeam(unitID)
	if myAllyID and unitAllyID and myAllyID == unitAllyID then
		return true
	end
	return false
end

function M.addFinishedUnit(unitID, unitDefID, unitTeam)
	if not unitID then return end
	if not M.isFriendlyUnit(unitID, unitTeam) then return end
	if not M.unitIsFinished(unitID) then return end

	unitDefID = unitDefID or (Spring.GetUnitDefID and Spring.GetUnitDefID(unitID))
	local unitDef = unitDefID and UnitDefs[unitDefID]
	if unitDef then
		local ux, uz = M.getUnitXZ(unitID)
		if ux and uz then
			State.finishedUnits[unitID] = {
				defID = unitDefID,
				x = ux,
				z = uz,
				facing = M.unitFacing(unitID),
			}
			State.finishedGroundDirty = true
		end
	end
end

function M.addTrackedBuilder(unitID, unitDefID, unitTeam)
	if not unitID then return end
	if not M.isFriendlyUnit(unitID, unitTeam) then return end
	unitDefID = unitDefID or (Spring.GetUnitDefID and Spring.GetUnitDefID(unitID))
	local unitDef = unitDefID and UnitDefs[unitDefID]
	if unitDef and unitDef.isBuilder and not unitDef.isFactory
		and type(unitDef.buildOptions) == "table" and #unitDef.buildOptions > 0
	then
		State.trackedBuilders[unitID] = true
	end
end

function M.rebuildFinishedUnits()
	State.finishedUnits = {}
	State.trackedBuilders = {}
	State.finishedGroundDirty = true

	local isSpec = Spring.GetSpectatingFullView and Spring.GetSpectatingFullView()
	State.myTeamID = Spring.GetMyTeamID and Spring.GetMyTeamID()
	local myAllyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()

	if isSpec or not State.myTeamID or State.myTeamID < 0 then
		if Spring.GetAllUnits then
			for _, unitID in ipairs(Spring.GetAllUnits() or {}) do
				M.addFinishedUnit(unitID)
				M.addTrackedBuilder(unitID)
			end
		end
		return
	end

	if Spring.GetTeamUnits then
		for _, unitID in ipairs(Spring.GetTeamUnits(State.myTeamID) or {}) do
			M.addFinishedUnit(unitID)
			M.addTrackedBuilder(unitID)
		end
	end

	if myAllyID and Spring.GetTeamList and Spring.GetTeamUnits then
		for _, teamID in ipairs(Spring.GetTeamList(myAllyID) or {}) do
			if teamID ~= State.myTeamID then
				for _, unitID in ipairs(Spring.GetTeamUnits(teamID) or {}) do
					M.addFinishedUnit(unitID)
				end
			end
		end
	end
end

function M.queuedBuildKey(buildDefID, buildX, buildZ, facing)
	return buildDefID .. ":" .. math.floor(buildX + 0.5) .. ":" .. math.floor(buildZ + 0.5) .. ":" .. facing
end

function M.queuedBuildTablesMatch(left, right)
	for key, build in pairs(left) do
		local other = right[key]
		if not other
			or other.defID ~= build.defID
			or other.x ~= build.x
			or other.z ~= build.z
			or other.facing ~= build.facing
		then
			return false
		end
	end
	for key in pairs(right) do
		if not left[key] then return false end
	end
	return true
end

function M.rebuildQueuedBuilds()
	local nextQueuedBuilds = {}
	if not State.myTeamID or not Spring.GetUnitCommands then
		if next(State.queuedBuilds) then State.queuedGroundDirty = true end
		State.queuedBuilds = nextQueuedBuilds
		return
	end

	for builderID in pairs(State.trackedBuilders) do
		for _, command in ipairs(Spring.GetUnitCommands(builderID, CONST.QUEUE_COMMAND_SCAN_LIMIT) or {}) do
			local commandID = tonumber(command.id)
			local params = command.params
			if commandID and commandID < 0 and type(params) == "table" then
				local buildDefID = -commandID
				local buildDef = UnitDefs[buildDefID]
				local buildX = tonumber(params[1])
				local buildZ = tonumber(params[3])
				local facing = tonumber(params[4]) or 0
				if buildDef and buildX and buildZ then
					facing = math.floor(facing + 0.5) % 4
					local key = M.queuedBuildKey(buildDefID, buildX, buildZ, facing)
					nextQueuedBuilds[key] = {
						defID = buildDefID,
						x = buildX,
						z = buildZ,
						facing = facing,
					}
				end
			end
		end
	end

	if not M.queuedBuildTablesMatch(State.queuedBuilds, nextQueuedBuilds) then
		State.queuedGroundDirty = true
	end
	State.queuedBuilds = nextQueuedBuilds
end

function M.copyQueuedBuild(commandData)
	if type(commandData) ~= "table" or commandData.teamId ~= State.myTeamID then return end
	local buildDefID = tonumber(commandData.unitDefId)
	local buildX = tonumber(commandData.positionX)
	local buildZ = tonumber(commandData.positionZ)
	local facing = tonumber(commandData.rotation) or 0
	local buildDef = buildDefID and UnitDefs[buildDefID]
	if not buildDef or not buildX or not buildZ then return end

	facing = math.floor(facing + 0.5) % 4
	local key = M.queuedBuildKey(buildDefID, buildX, buildZ, facing)
	local current = State.queuedBuilds[key]
	if current
		and current.defID == buildDefID
		and current.x == buildX
		and current.z == buildZ
		and current.facing == facing
	then
		return
	end

	State.queuedBuilds[key] = {
		defID = buildDefID,
		x = buildX,
		z = buildZ,
		facing = facing,
	}
	State.queuedGroundDirty = true
end

function M.removeQueuedBuild(_, commandData)
	if type(commandData) ~= "table" or commandData.teamId ~= State.myTeamID then return end
	local buildDefID = tonumber(commandData.unitDefId)
	local buildX = tonumber(commandData.positionX)
	local buildZ = tonumber(commandData.positionZ)
	local facing = math.floor((tonumber(commandData.rotation) or 0) + 0.5) % 4
	if not buildDefID or not buildX or not buildZ then return end
	local key = M.queuedBuildKey(buildDefID, buildX, buildZ, facing)
	if State.queuedBuilds[key] then
		State.queuedBuilds[key] = nil
		State.queuedGroundDirty = true
	end
end

function M.registerBuilderQueueCallback(registerFunction, callback)
	if type(registerFunction) ~= "function" then return end
	local callbackData = registerFunction(callback)
	if callbackData then
		State.builderQueueCallbacks[#State.builderQueueCallbacks + 1] = callbackData
	end
end

function M.initializeBuilderQueueAPI()
	State.builderQueueAPI = WG and WG.BuilderQueueApi
	if type(State.builderQueueAPI) ~= "table" then return false end
	if type(State.builderQueueAPI.OnBuildCommandAdded) ~= "function"
		or type(State.builderQueueAPI.OnBuildCommandRemoved) ~= "function"
		or type(State.builderQueueAPI.UnregisterCallback) ~= "function"
	then
		State.builderQueueAPI = nil
		return false
	end

	M.registerBuilderQueueCallback(State.builderQueueAPI.OnBuildCommandAdded, function(_, commandData)
		M.copyQueuedBuild(commandData)
	end)
	M.registerBuilderQueueCallback(State.builderQueueAPI.OnBuildCommandRemoved, M.removeQueuedBuild)
	State.usingBuilderQueueAPI = true
	return true
end

function M.shutdownBuilderQueueAPI()
	if State.builderQueueAPI and type(State.builderQueueAPI.UnregisterCallback) == "function" then
		for index = 1, #State.builderQueueCallbacks do
			local callbackData = State.builderQueueCallbacks[index]
			if callbackData then
				State.builderQueueAPI.UnregisterCallback(callbackData.eventName, callbackData.callback)
			end
		end
	end
	State.builderQueueCallbacks = {}
	State.builderQueueAPI = nil
	State.usingBuilderQueueAPI = false
end

function M.emitFullColoredFootprint(unitDef, x, z, facing, heightOffset)
	facing = facing or 0
	local xsize = ((facing % 2) == 0) and unitDef.xsize or unitDef.zsize
	local zsize = ((facing % 2) == 1) and unitDef.xsize or unitDef.zsize
	if not xsize or not zsize then return end

	local sx = math.floor(x / CONST.ENGINE_SQUARE_SIZE) - math.floor(xsize / 2)
	local sz = math.floor(z / CONST.ENGINE_SQUARE_SIZE) - math.floor(zsize / 2)
	for zi = 0, zsize - 1, CONST.COLORED_CELL_NATIVE_SPAN do
		local nativeZEnd = math.min(zi + CONST.COLORED_CELL_NATIVE_SPAN - 1, zsize - 1)
		for xi = 0, xsize - 1, CONST.COLORED_CELL_NATIVE_SPAN do
			local nativeXEnd = math.min(xi + CONST.COLORED_CELL_NATIVE_SPAN - 1, xsize - 1)
			local wx0 = math.max(0, (sx + xi) * CONST.ENGINE_SQUARE_SIZE + CONST.COLORED_CELL_INSET)
			local wz0 = math.max(0, (sz + zi) * CONST.ENGINE_SQUARE_SIZE + CONST.COLORED_CELL_INSET)
			local wx1 = math.min(CONST.MAP_SIZE_X, (sx + nativeXEnd + 1) * CONST.ENGINE_SQUARE_SIZE - CONST.COLORED_CELL_INSET)
			local wz1 = math.min(CONST.MAP_SIZE_Z, (sz + nativeZEnd + 1) * CONST.ENGINE_SQUARE_SIZE - CONST.COLORED_CELL_INSET)
			if wx1 > wx0 and wz1 > wz0 then
				M.emitRoundedColorFill(
					wx0, wz0, wx1, wz1,
					heightOffset,
					CONST.COLORED_CELL_CORNER_RADIUS
				)
			end
		end
	end
end

function M.drawQueuedBuildGround()
	gl.Color(1.0, 0.78, 0.04, CONST.QUEUED_FILL_ALPHA)
	gl.BeginEnd(GL_ENUMS.TRIANGLES, function()
		for _, build in pairs(State.queuedBuilds) do
			local unitDef = UnitDefs[build.defID]
			if unitDef then
				M.emitFullColoredFootprint(unitDef, build.x, build.z, build.facing, CONST.QUEUED_FILL_OFFSET)
			end
		end
	end)
end

function M.drawFinishedUnitGround()
	gl.Color(1.0, 0.45, 0.05, CONST.BUILT_UNIT_FILL_ALPHA)
	gl.BeginEnd(GL_ENUMS.TRIANGLES, function()
		for unitID, info in pairs(State.finishedUnits) do
			local unitDef = UnitDefs[info.defID]
			local ux, uz = M.getUnitXZ(unitID)
			ux = ux or info.x
			uz = uz or info.z
			if unitDef and ux and uz then
				M.emitFullColoredFootprint(unitDef, ux, uz, info.facing or 0, CONST.BUILT_UNIT_FILL_OFFSET)
			end
		end
	end)
end

function M.rebuildQueuedFillBatch()
	local instanceCount = 0
	for _, build in pairs(State.queuedBuilds) do
		local unitDef = UnitDefs[build.defID]
		if unitDef then
			instanceCount = M.appendFootprintFillInstances(
				State.queuedFillScratch, instanceCount, unitDef, build.x, build.z, build.facing
			)
		end
	end
	if not M.uploadFillBatch("queued", State.queuedFillScratch, instanceCount) then return false end
	State.queuedGroundDirty = false
	return true
end

function M.rebuildFinishedFillBatch()
	local instanceCount = 0
	for unitID, info in pairs(State.finishedUnits) do
		local unitDef = UnitDefs[info.defID]
		local ux, uz = M.getUnitXZ(unitID)
		ux = ux or info.x
		uz = uz or info.z
		if unitDef and ux and uz then
			instanceCount = M.appendFootprintFillInstances(
				State.finishedFillScratch, instanceCount, unitDef, ux, uz, info.facing or 0
			)
		end
	end
	if not M.uploadFillBatch("finished", State.finishedFillScratch, instanceCount) then return false end
	State.finishedGroundDirty = false
	return true
end

function M.deleteDisplayList(displayList)
	if displayList and gl.DeleteList then
		gl.DeleteList(displayList)
	end
end

function M.drawCachedQueuedGround()
	if State.fillGL4Ready then
		if State.queuedGroundDirty and not M.rebuildQueuedFillBatch() then
			M.freeFillGL4()
		end
		if State.fillGL4Ready then
			M.drawFillBatch("queued", 1.0, 0.78, 0.04, CONST.QUEUED_FILL_ALPHA, CONST.QUEUED_FILL_OFFSET)
			return
		end
	end
	if not (gl.CreateList and gl.CallList and gl.DeleteList) then
		M.drawQueuedBuildGround()
		return
	end
	if State.queuedGroundDirty then
		M.deleteDisplayList(State.queuedGroundList)
		State.queuedGroundList = gl.CreateList(M.drawQueuedBuildGround)
		State.queuedGroundDirty = false
	end
	if State.queuedGroundList then
		gl.CallList(State.queuedGroundList)
	else
		M.drawQueuedBuildGround()
	end
end

function M.drawCachedFinishedGround()
	if State.fillGL4Ready then
		if not M.rebuildFinishedFillBatch() then
			M.freeFillGL4()
		end
		if State.fillGL4Ready then
			M.drawFillBatch("finished", 1.0, 0.45, 0.05, CONST.BUILT_UNIT_FILL_ALPHA, CONST.BUILT_UNIT_FILL_OFFSET)
			return
		end
	end
	M.drawFinishedUnitGround()
end

function M.drawAllGroundFills()
	if State.fillGL4Ready then
		if State.queuedGroundDirty and not M.rebuildQueuedFillBatch() then
			M.freeFillGL4()
		end
		if not M.rebuildFinishedFillBatch() then
			M.freeFillGL4()
		end
		if State.fillGL4Ready then
			local queuedBatch = State.fillBatches["queued"]
			local finishedBatch = State.fillBatches["finished"]
			local hasQueued = queuedBatch and queuedBatch.count > 0
			local hasFinished = finishedBatch and finishedBatch.count > 0

			if hasQueued or hasFinished then
				gl.Texture(0, "$heightmap")
				State.fillShader:Activate()
				if State.fillCellInsetUniform then gl.Uniform(State.fillCellInsetUniform, CONST.COLORED_CELL_INSET) end
				if State.fillCornerRadiusUniform then gl.Uniform(State.fillCornerRadiusUniform, CONST.COLORED_CELL_CORNER_RADIUS) end

				if hasQueued then
					gl.Uniform(State.fillHeightOffsetUniform, CONST.QUEUED_FILL_OFFSET)
					gl.Uniform(State.fillColorUniform, 1.0, 0.78, 0.04, CONST.QUEUED_FILL_ALPHA)
					queuedBatch.vao:DrawElements(GL_ENUMS.TRIANGLES, State.fillIndexCount, 0, queuedBatch.count)
				end

				if hasFinished then
					gl.Uniform(State.fillHeightOffsetUniform, CONST.BUILT_UNIT_FILL_OFFSET)
					gl.Uniform(State.fillColorUniform, 1.0, 0.45, 0.05, CONST.BUILT_UNIT_FILL_ALPHA)
					finishedBatch.vao:DrawElements(GL_ENUMS.TRIANGLES, State.fillIndexCount, 0, finishedBatch.count)
				end

				State.fillShader:Deactivate()
				gl.Texture(0, false)
			end
			return
		end
	end

	M.drawCachedQueuedGround()
	M.drawCachedFinishedGround()
end

function M.drawCachedRoundedGrid(centerX, centerZ, alignmentX, alignmentZ)
	if not (gl.CreateList and gl.CallList and gl.DeleteList) then
		M.drawRoundedGrid(centerX, centerZ, CONST.GRID_RADIUS, alignmentX, alignmentZ)
		return
	end
	if State.roundedGridDirty
		or State.roundedGridListX ~= centerX
		or State.roundedGridListZ ~= centerZ
		or State.roundedGridListAlignmentX ~= alignmentX
		or State.roundedGridListAlignmentZ ~= alignmentZ
	then
		M.deleteDisplayList(State.roundedGridList)
		State.roundedGridList = gl.CreateList(M.drawRoundedGrid, centerX, centerZ, CONST.GRID_RADIUS, alignmentX, alignmentZ)
		State.roundedGridListX = centerX
		State.roundedGridListZ = centerZ
		State.roundedGridListAlignmentX = alignmentX
		State.roundedGridListAlignmentZ = alignmentZ
		State.roundedGridDirty = false
	end
	if State.roundedGridList then
		gl.CallList(State.roundedGridList)
	else
		M.drawRoundedGrid(centerX, centerZ, CONST.GRID_RADIUS, alignmentX, alignmentZ)
	end
end

function M.invalidateTerrainDrawCaches()
	if not State.gridGL4Ready then State.roundedGridDirty = true end
	if not State.fillGL4Ready then
		State.finishedGroundDirty = true
		State.queuedGroundDirty = true
	end
end

function M.freeDisplayLists()
	M.deleteDisplayList(State.roundedGridList)
	M.deleteDisplayList(State.finishedGroundList)
	M.deleteDisplayList(State.queuedGroundList)
	State.roundedGridList = nil
	State.finishedGroundList = nil
	State.queuedGroundList = nil
end

--------------------------------------------------------------------------------
-- Widget Lifecycle Callbacks
--------------------------------------------------------------------------------

function widget:Initialize()
	M.rebuildFinishedUnits()
	M.initializeBuilderQueueAPI()
	local whiteGridGPU = M.initializeGridGL4()
	local coloredFillGPU = M.initializeFillGL4()
	if not coloredFillGPU then M.freeFillGL4() end
	M.rebuildQueuedBuilds()
	Spring.Echo("[Build Grid 2.0] ready (white "
		.. (whiteGridGPU and "GPU" or "CPU") .. ", fills "
		.. (coloredFillGPU and "GPU" or "CPU") .. ")")
end

function widget:TextCommand(command)
	command = string.lower(command or "")
	if command == "constructiongrid" or command == "constructiongrid toggle" then
		State.enabled = not State.enabled
		if State.enabled then State.queueRefreshPending = true end
		Spring.Echo("[Build Grid 2.0] " .. (State.enabled and "enabled" or "disabled"))
	end
end

function widget:PlayerChanged()
	M.rebuildFinishedUnits()
	State.queuedBuilds = {}
	State.queuedGroundDirty = true
	M.rebuildQueuedBuilds()
end

function widget:GameStart()
	M.rebuildFinishedUnits()
	State.queuedBuilds = {}
	State.queuedGroundDirty = true
	M.rebuildQueuedBuilds()
end

function widget:GameFrame(n)
	if n % 15 == 0 then
		M.rebuildFinishedUnits()
	end
end

function widget:Update(deltaTime)
	if not State.usingBuilderQueueAPI then
		State.queueAPIRecheckElapsed = State.queueAPIRecheckElapsed + (deltaTime or 0)
		if State.queueAPIRecheckElapsed >= CONST.QUEUE_API_RECHECK_SECONDS then
			State.queueAPIRecheckElapsed = 0
			if M.initializeBuilderQueueAPI() then
				M.rebuildQueuedBuilds()
				return
			end
		end
	end

	local buildModeActive = State.enabled
		and not (Spring.IsGUIHidden and Spring.IsGUIHidden())
		and M.isBuildModeActive()
	if not buildModeActive then
		State.buildModeWasActive = false
		State.queueRefreshElapsed = 0
		return
	end

	if not State.buildModeWasActive then
		State.buildModeWasActive = true
		State.queueRefreshPending = true
	end

	State.queueRefreshElapsed = State.queueRefreshElapsed + (deltaTime or 0)
	if State.queueRefreshPending or State.queueRefreshElapsed >= CONST.QUEUE_REFRESH_SECONDS then
		State.queueRefreshElapsed = 0
		State.queueRefreshPending = false
		M.rebuildQueuedBuilds()
		M.rebuildFinishedUnits()
	end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
	M.addTrackedBuilder(unitID, unitDefID, unitTeam)
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	M.addTrackedBuilder(unitID, unitDefID, unitTeam)
	M.addFinishedUnit(unitID, unitDefID, unitTeam)
end

function widget:UnitGiven(unitID, unitDefID)
	M.addTrackedBuilder(unitID, unitDefID, Spring.GetUnitTeam and Spring.GetUnitTeam(unitID))
	M.addFinishedUnit(unitID, unitDefID, Spring.GetUnitTeam and Spring.GetUnitTeam(unitID))
	State.queueRefreshPending = true
end

function widget:UnitTaken(unitID)
	if State.finishedUnits[unitID] then State.finishedGroundDirty = true end
	State.finishedUnits[unitID] = nil
	State.trackedBuilders[unitID] = nil
	State.queueRefreshPending = true
end

function widget:UnitDestroyed(unitID)
	if State.finishedUnits[unitID] then State.finishedGroundDirty = true end
	State.finishedUnits[unitID] = nil
	State.trackedBuilders[unitID] = nil
	State.queueRefreshPending = true
end

function widget:UnitCommand(unitID)
	if State.trackedBuilders[unitID] then State.queueRefreshPending = true end
end

function widget:UnitCmdDone(unitID)
	if State.trackedBuilders[unitID] then State.queueRefreshPending = true end
end

function widget:UnitIdle(unitID)
	if State.trackedBuilders[unitID] then State.queueRefreshPending = true end
end

function widget:UnsyncedHeightMapUpdate()
	M.invalidateTerrainDrawCaches()
end

function widget:Shutdown()
	M.shutdownBuilderQueueAPI()
	M.freeDisplayLists()
	M.freeFillGL4()
	M.freeGridGL4()
end

function widget:GetConfigData()
	return {enabled = State.enabled}
end

function widget:SetConfigData(data)
	if type(data) == "table" and data.enabled ~= nil then
		State.enabled = data.enabled ~= false
	end
end

function widget:DrawWorldPreUnit()
	if not State.enabled then return end
	if Spring.IsGUIHidden and Spring.IsGUIHidden() then return end
	if not M.isBuildModeActive() then
		State.activeBuildSquare = nil
		return
	end

	gl.DepthTest(true)
	if gl.DepthMask then gl.DepthMask(false) end
	if gl.PolygonOffset then gl.PolygonOffset(-25, -25) end
	if gl.CullFace then gl.CullFace(false) elseif gl.Culling then gl.Culling(false) end
	gl.Blending(GL_ENUMS.SRC_ALPHA, GL_ENUMS.ONE_MINUS_SRC_ALPHA)

	M.drawAllGroundFills()

	gl.Color(1, 1, 1, 1)
	if gl.PolygonOffset then gl.PolygonOffset(0, 0) end
	if gl.DepthMask then gl.DepthMask(true) end
	if gl.CullFace then gl.CullFace(true) elseif gl.Culling then gl.Culling(true) end
	gl.DepthTest(false)
	gl.Blending(false)
end

function widget:DrawBuildSquare(unitDefID, x, z, facing, statuses)
	if not State.enabled then return end
	if Spring.IsGUIHidden and Spring.IsGUIHidden() then return end
	if not unitDefID or not x or not z then return end

	gl.DepthTest(true)
	if gl.DepthMask then gl.DepthMask(false) end
	if gl.PolygonOffset then gl.PolygonOffset(-25, -25) end
	if gl.CullFace then gl.CullFace(false) elseif gl.Culling then gl.Culling(false) end
	gl.Blending(GL_ENUMS.SRC_ALPHA, GL_ENUMS.ONE_MINUS_SRC_ALPHA)

	M.drawOccupiedCells(unitDefID, x, z, facing, statuses)
	M.drawFootprintOutline(unitDefID, x, z, facing)

	gl.Color(1, 1, 1, 1)
	if gl.PolygonOffset then gl.PolygonOffset(0, 0) end
	if gl.DepthMask then gl.DepthMask(true) end
	if gl.CullFace then gl.CullFace(true) elseif gl.Culling then gl.Culling(true) end
	gl.DepthTest(false)
	gl.Blending(false)

	-- Save the latest/front-most unit in the drag sequence for drawing the white base grid
	State.activeBuildSquare = {
		unitDefID = unitDefID,
		x = x,
		z = z,
		facing = facing,
		time = os.clock(),
	}
end

function widget:DrawWorld()
	if not State.enabled then return end
	if Spring.IsGUIHidden and Spring.IsGUIHidden() then return end
	if not M.isBuildModeActive() then
		State.activeBuildSquare = nil
		return
	end

	local bs = State.activeBuildSquare
	if not bs or (os.clock() - (bs.time or 0)) > 0.25 then return end

	gl.DepthTest(true)
	if gl.DepthMask then gl.DepthMask(false) end
	if gl.PolygonOffset then gl.PolygonOffset(-25, -25) end
	if gl.CullFace then gl.CullFace(false) elseif gl.Culling then gl.Culling(false) end
	gl.Blending(GL_ENUMS.SRC_ALPHA, GL_ENUMS.ONE_MINUS_SRC_ALPHA)

	local alignmentX, alignmentZ = M.footprintGridAlignment(bs.unitDefID, bs.x, bs.z, bs.facing)
	if not M.drawRoundedGridGL4(bs.x, bs.z, alignmentX, alignmentZ) then
		M.drawCachedRoundedGrid(bs.x, bs.z, alignmentX, alignmentZ)
	end

	gl.Color(1, 1, 1, 1)
	if gl.PolygonOffset then gl.PolygonOffset(0, 0) end
	if gl.DepthMask then gl.DepthMask(true) end
	if gl.CullFace then gl.CullFace(true) elseif gl.Culling then gl.Culling(true) end
	gl.DepthTest(false)
	gl.Blending(false)
end
