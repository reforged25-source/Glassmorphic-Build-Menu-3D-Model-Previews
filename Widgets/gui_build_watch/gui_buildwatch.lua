local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Build Watch 2.0",
        desc = "Displays organized icons for all units under construction, showing build progress and estimated completion times with event-driven zero-polling performance. (v2.0 by reforged25-source)",
        author = "reforged25-source / Codex (orig: 2Bit)",
        version = "2.0",
        date = "2026 (v2.0)",
        license = "GNU GPL, v2 or later",
        layer = 2,
        enabled = true,
    }
end

local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetGameSeconds = Spring.GetGameSeconds
local spGetGameFrame = Spring.GetGameFrame
local spSetCameraTarget = Spring.SetCameraTarget
local spGetUnitPosition = Spring.GetUnitPosition
local spGetFullBuildQueue = Spring.GetFullBuildQueue
local spValidUnitID = Spring.ValidUnitID
local spGetViewGeometry = Spring.GetViewGeometry
local spGetConfigFloat = Spring.GetConfigFloat
local glColor = gl.Color
local glTexture = gl.Texture
local glTexRect = gl.TexRect
local glRect = gl.Rect
local glUnitShape = gl.UnitShape
local glRotate = gl.Rotate
local glScale = gl.Scale
local glTranslate = gl.Translate
local glPushMatrix = gl.PushMatrix
local glPopMatrix = gl.PopMatrix
local glScissor = gl.Scissor
local glLighting = gl.Lighting
local glMaterial = gl.Material
local glClear = gl.Clear
local glDepthTest = gl.DepthTest
local glDepthMask = gl.DepthMask
local glBlending = gl.Blending
local glLineWidth = gl.LineWidth
local glBeginEnd = gl.BeginEnd
local GL_DEPTH_BUFFER_BIT = (GL and GL.DEPTH_BUFFER_BIT) or 0x0100
local GL_LINE_LOOP = (GL and GL.LINE_LOOP) or 0x0002

local floor = math.floor
local max = math.max
local min = math.min
local sformat = string.format

local MODEL_ROTATION_SPEED = 4.5 -- degrees per second; slower and smoother rotation
local MODEL_CAMERA_PITCH = 35 -- degrees; top-down isometric view
local MODEL_FRONT_YAW = 0 -- face the camera at the center of the motion
local MODEL_ROTATION_LIMIT = 50 -- degrees to either side of the front (ping-pong oscillation)
local MODEL_ACTIONS = {
    {name = "Idle", duration = 4.8, bob = 0.6, sway = 0.5, tilt = 0.35, waveCycles = 1, scalePulse = 0.004},
}
local modelRotation = 0
local modelActionBob = 0
local modelActionTilt = 0
local modelActionScale = 1.0
local modelDimensions = {}

local BASE_CARD_WIDTH = 195
local BASE_CARD_HEIGHT = 162

local function getSystemUIScale()
    local sysScale = 1.0
    if spGetConfigFloat then
        sysScale = tonumber(spGetConfigFloat("ui_scale", 1) or 1.0) or 1.0
    end
    return sysScale
end

local function getUIScale()
    local vsx, vsy = spGetViewGeometry()
    local sysScale = getSystemUIScale()
    local resScale = math.max(0.55, math.min(1.15, (0.70 + (vsx * vsy / 8000000)) * 0.82))
    return math.max(0.45, math.min(1.60, sysScale * resScale))
end

local myTeamID = Spring.GetMyTeamID()

local config = {
    show3DWorld = true,
    show2DScreen = true,
    worldScale = 1.0,
}

-- Event-driven tracking sets (Eliminates full team polling)
local trackedFactories = {}
local trackedUnderConstruction = {}

local factoryUnits = {}
local otherUnits = {}
local iconSize = 144 -- 3x larger (scaled from 48 to 144)
local font
local etaState = {}
local updateInterval = 0.2  -- Update ETA calculations 5Hz
local lastUpdateTime = 0
local iconAreas = {}

-- Reusable cache tables
local activeUnitIDs = {}
local factoryBuiltSet = {}

local function updateETAState(unitID, buildProgress)
    local gs = spGetGameSeconds()
    local state = etaState[unitID]
    if not state then
        state = {
            firstSet = true,
            lastTime = gs,
            lastProg = buildProgress,
            rate = nil,
            timeLeft = nil,
            prevTimeLeft = nil,
            decaying = false,
            decayTime = nil,
        }
    end

    activeUnitIDs[unitID] = true

    local dp = buildProgress - (state.lastProg or buildProgress)
    local dt = gs - (state.lastTime or gs)

    if buildProgress >= 1 then
        state.decaying = false
        state.decayTime = nil
    end

    if dt > 2 then
        state.firstSet = true
        state.rate = nil
        state.timeLeft = nil
    end

    local rate = dt > 0 and (dp / dt) or 0
    if rate > 0 then
        state.decaying = false
        state.decayTime = nil
        if state.firstSet then
            if buildProgress > 0.001 then
                state.firstSet = false
            end
        else
            local rf = 0.5
            if state.rate == nil then
                state.rate = rate
            else
                state.rate = ((1 - rf) * state.rate) + (rf * rate)
            end

            local tf = 0.1
            local newTime = (1 - buildProgress) / state.rate
            if state.timeLeft and state.timeLeft > 0 then
                state.timeLeft = ((1 - tf) * state.timeLeft) + (tf * newTime)
            else
                state.timeLeft = newTime
            end
        end
    elseif rate < 0 or (state.decaying and buildProgress > 0 and buildProgress < 1) then
        state.decaying = true
        local decayRate = 1 / 60
        state.decayTime = buildProgress / decayRate
        state.timeLeft = nil
    end

    state.lastTime = gs
    state.lastProg = buildProgress
    state.prevTimeLeft = state.timeLeft

    etaState[unitID] = state
    return state
end

local function scanInitialUnits()
    trackedFactories = {}
    trackedUnderConstruction = {}
    local units = spGetTeamUnits(myTeamID)
    if not units then return end

    for i = 1, #units do
        local uid = units[i]
        local defID = spGetUnitDefID(uid)
        local ud = defID and UnitDefs[defID]
        if ud then
            if ud.isFactory then
                trackedFactories[uid] = true
            end
            local isBeingBuilt = spGetUnitIsBeingBuilt(uid)
            if isBeingBuilt then
                trackedUnderConstruction[uid] = defID
            end
        end
    end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
    if unitTeam == myTeamID then
        local ud = UnitDefs[unitDefID]
        if ud and ud.isFactory then
            trackedFactories[unitID] = true
        end
        local isBeingBuilt = spGetUnitIsBeingBuilt(unitID)
        if isBeingBuilt then
            trackedUnderConstruction[unitID] = unitDefID
        end
    end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    if unitTeam == myTeamID then
        local ud = UnitDefs[unitDefID]
        if ud and ud.isFactory then
            trackedFactories[unitID] = true
        end
        trackedUnderConstruction[unitID] = nil
        etaState[unitID] = nil
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
    if unitTeam == myTeamID then
        trackedFactories[unitID] = nil
        trackedUnderConstruction[unitID] = nil
        etaState[unitID] = nil
    end
end

function widget:UnitGiven(unitID, unitDefID, unitTeam, oldTeam)
    if unitTeam == myTeamID then
        local ud = UnitDefs[unitDefID]
        if ud and ud.isFactory then
            trackedFactories[unitID] = true
        end
        local isBeingBuilt = spGetUnitIsBeingBuilt(unitID)
        if isBeingBuilt then
            trackedUnderConstruction[unitID] = unitDefID
        end
    else
        trackedFactories[unitID] = nil
        trackedUnderConstruction[unitID] = nil
        etaState[unitID] = nil
    end
end

function widget:UnitTaken(unitID, unitDefID, unitTeam, newTeam)
    if unitTeam == myTeamID then
        trackedFactories[unitID] = nil
        trackedUnderConstruction[unitID] = nil
        etaState[unitID] = nil
    end
end

local function drawText(value, x, y, size, color, options)
    if not value or value == "" then return end
    if not font and WG and WG.fonts then
        font = WG.fonts.getFont(2, 1.0)
    end
    local drawn = false
    if font and font.Print and font.Begin and font.End then
        local ok = pcall(function()
            font:Begin()
            font:SetTextColor(color[1], color[2], color[3], color[4] or 1)
            font:Print(value, x, y, size, options or "o")
            font:End()
        end)
        if ok then drawn = true end
    end
    if not drawn then
        glColor(color[1], color[2], color[3], color[4] or 1)
        gl.Text(value, x, y, size, options or "o")
    end
end

local strategicIconBitmaps = {}

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

local function drawStrategicIcon(x, y, size, unitDefID)
    local bitmap = strategicIconBitmaps[unitDefID]
    if bitmap then
        glColor(1, 1, 1, 1)
        glTexture(":l:" .. bitmap)
        glTexRect(x, y, x + size, y + size)
        glTexture(false)
        return
    end

    local def = UnitDefs and UnitDefs[unitDefID]
    local iconType = def and def.iconType
    if iconType and iconType ~= "" then
        glColor(0.10, 0.12, 0.15, 0.92)
        glRect(x, y, x + size, y + size)
        drawText(string.upper(iconType:sub(1, 1)), x + size * 0.5, y + size * 0.5, 9, {1, 1, 1, 1}, "voco")
    end
end

function widget:Initialize()
    myTeamID = Spring.GetMyTeamID()
    if WG['fonts'] then
        font = WG['fonts'].getFont(2)
    end
    refreshStrategicIcons()
    scanInitialUnits()
end

function widget:ViewResize()
    if WG['fonts'] then
        font = WG['fonts'].getFont(2)
    end
end

function widget:PlayerChanged()
    myTeamID = Spring.GetMyTeamID()
    scanInitialUnits()
end

function widget:Update(dt)
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
    local progressInAction = (actionClock - actionStart) / action.duration
    local cycleProgress = (progressInAction * action.waveCycles) % 1.0
    local motionPhase = cycleProgress * math.pi * 2

    modelActionBob = math.sin(motionPhase) * action.bob
    modelActionTilt = math.sin(motionPhase) * action.tilt
    modelActionScale = 1.0 + math.sin(motionPhase) * action.scalePulse

    local currentTime = spGetGameSeconds()
    if currentTime - lastUpdateTime < updateInterval then
        return
    end
    lastUpdateTime = currentTime

    -- Clear reusable arrays
    for i = #factoryUnits, 1, -1 do factoryUnits[i] = nil end
    for i = #otherUnits, 1, -1 do otherUnits[i] = nil end
    for k in pairs(factoryBuiltSet) do factoryBuiltSet[k] = nil end

    local newActiveUnitIDs = {}

    -- 1. Check tracked factories for units currently being produced & queued
    for facID in pairs(trackedFactories) do
        if spValidUnitID(facID) and spGetUnitTeam(facID) == myTeamID then
            local builtID = spGetUnitIsBuilding(facID)
            local fullQueue = spGetFullBuildQueue and spGetFullBuildQueue(facID)

            if builtID and spValidUnitID(builtID) then
                local isBeingBuilt, progress = spGetUnitIsBeingBuilt(builtID)
                if isBeingBuilt then
                    local builtDefID = spGetUnitDefID(builtID)
                    local currentCount = 1
                    if fullQueue and fullQueue[1] then
                        for _, c in pairs(fullQueue[1]) do
                            currentCount = c
                            break
                        end
                    end
                    factoryUnits[#factoryUnits + 1] = {
                        unitID = builtID,
                        unitDefID = builtDefID,
                        progress = progress,
                        facID = facID,
                        isQueued = false,
                        count = currentCount,
                    }
                    factoryBuiltSet[builtID] = true
                    updateETAState(builtID, progress)
                    newActiveUnitIDs[builtID] = true
                end
            end

            -- Subsequent queued items in this factory
            if fullQueue and #fullQueue > 1 then
                for qIdx = 2, #fullQueue do
                    local entry = fullQueue[qIdx]
                    if type(entry) == "table" then
                        for qDefID, qCount in pairs(entry) do
                            factoryUnits[#factoryUnits + 1] = {
                                unitID = facID,
                                unitDefID = qDefID,
                                progress = 0,
                                facID = facID,
                                isQueued = true,
                                count = qCount,
                                queueIndex = qIdx,
                            }
                        end
                    end
                end
            end
        else
            trackedFactories[facID] = nil
        end
    end

    -- 2. Check field units under construction
    for unitID, defID in pairs(trackedUnderConstruction) do
        if not factoryBuiltSet[unitID] then
            if spValidUnitID(unitID) and spGetUnitTeam(unitID) == myTeamID then
                local isBeingBuilt, progress = spGetUnitIsBeingBuilt(unitID)
                if isBeingBuilt then
                    otherUnits[#otherUnits + 1] = { unitID = unitID, unitDefID = defID, progress = progress }
                    updateETAState(unitID, progress)
                    newActiveUnitIDs[unitID] = true
                else
                    trackedUnderConstruction[unitID] = nil
                end
            else
                trackedUnderConstruction[unitID] = nil
            end
        end
    end

    -- Clean up finished units from etaState
    for unitID in pairs(activeUnitIDs) do
        if not newActiveUnitIDs[unitID] then
            etaState[unitID] = nil
        end
    end
    activeUnitIDs = newActiveUnitIDs
end

local function getModelDimensions(unitDefID)
    local cached = modelDimensions[unitDefID]
    if cached then return cached end
    local def = UnitDefs and UnitDefs[unitDefID]
    local dimensions = def and def.dimensions
    if not dimensions and Spring.GetUnitDefDimensions then
        dimensions = Spring.GetUnitDefDimensions(unitDefID)
    end
    if not dimensions then return nil end
    modelDimensions[unitDefID] = dimensions
    return dimensions
end

local function drawUnitModel(x, y, w, h, unitDefID)
    if not glUnitShape then return false end
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
    scale = scale * 0.74

    glTexture(false)
    glDepthTest(true)
    glDepthMask(true)
    glLighting(true)
    glBlending(false)
    glMaterial({
        ambient = {0.25, 0.25, 0.25, 1.0},
        diffuse = {1.0, 1.0, 1.0, 1.0},
        emission = {0.0, 0.0, 0.0, 1.0},
        specular = {0.25, 0.25, 0.25, 1.0},
        shininess = 16.0,
    })

    glPushMatrix()
    glScissor(floor(x), floor(y), max(1, floor(w)), max(1, floor(h)))
    glTranslate(x + w * 0.5, y + h * 0.44 + (modelActionBob or 0), 0)
    glRotate(MODEL_CAMERA_PITCH, 1, 0, 0)
    glRotate(modelRotation, 0, 1, 0)
    glRotate(modelActionTilt or 0, 0, 0, 1)
    local s = scale * (modelActionScale or 1.0)
    glScale(s, s, s)
    glTranslate(
        -0.5 * (dimensions.maxx + dimensions.minx),
        -0.5 * (dimensions.maxy + dimensions.miny),
        -0.5 * (dimensions.maxz + dimensions.minz)
    )
    glUnitShape(unitDefID, myTeamID or 0, false, true, true)
    glScissor(false)
    glPopMatrix()

    glBlending(true)
    glLighting(false)
    glDepthMask(false)
    glDepthTest(false)
    return true
end

local function formatCost(value)
    if not value or value == 0 then return "0" end
    if value >= 1000000 then
        return sformat("%.1fM", value / 1000000)
    elseif value >= 10000 then
        return sformat("%.1fk", value / 1000)
    elseif value >= 1000 then
        local k = value / 1000
        if k == floor(k) then
            return sformat("%dk", k)
        else
            return sformat("%.1fk", k)
        end
    else
        return sformat("%d", floor(value))
    end
end

local TIER_COLORS = {
    [1] = {0.35, 0.75, 1.00, 1.0}, -- T1: Cyan
    [2] = {1.00, 0.85, 0.20, 1.0}, -- T2: Gold/Yellow
    [3] = {0.85, 0.40, 1.00, 1.0}, -- T3: Purple
    [4] = {1.00, 0.35, 0.35, 1.0}, -- T4: Red
}

local ROLE_COLORS = {
    ["ASSAULT"] = {0.95, 0.35, 0.25, 1.0},
    ["RAIDER"] = {1.00, 0.70, 0.20, 1.0},
    ["SKIRMISH"] = {0.35, 0.85, 0.55, 1.0},
    ["ARTILLERY"] = {0.90, 0.45, 0.95, 1.0},
    ["RIOT"] = {0.45, 0.75, 1.00, 1.0},
    ["STRUCTURE"] = {0.60, 0.70, 0.80, 1.0},
    ["AIR"] = {0.30, 0.85, 0.95, 1.0},
    ["SEA"] = {0.25, 0.65, 1.00, 1.0},
    ["COMBAT"] = {0.70, 0.80, 0.90, 1.0},
    ["BOT"] = {0.40, 0.80, 0.95, 1.0},
    ["VEHICLE"] = {0.95, 0.75, 0.30, 1.0},
}

local function unitRoleLabel(def)
    if not def then return "COMBAT" end
    local cp = def.customParams
    if cp and cp.subrole then return string.upper(cp.subrole) end
    if cp and cp.role then return string.upper(cp.role) end
    if def.isBuilding then return "STRUCTURE" end
    if def.canFly then return "AIR" end
    if def.canSubmerge or (def.minWaterDepth and def.minWaterDepth > 0) then return "SEA" end
    if def.speed and def.speed > 80 then return "RAIDER" end
    if def.maxDamage and def.maxDamage > 5000 then return "ASSAULT" end
    return "COMBAT"
end

local function getTechTier(def)
    if not def then return 1 end
    local cp = def.customParams
    if cp and cp.techlevel then return tonumber(cp.techlevel) or 1 end
    if cp and cp.tier then return tonumber(cp.tier) or 1 end
    local m = def.metalCost or 0
    if m >= 8000 then return 3
    elseif m >= 1200 then return 2
    else return 1 end
end

local function getTextPixelWidth(textValue, size)
    if not textValue or textValue == "" then return 0 end
    if font and font.GetTextWidth then
        return font:GetTextWidth(textValue) * size
    end
    return #textValue * size * 0.6
end

-- Render complete card: Header (SVG Icon & Unit Name), 3D Model, Badges, Price Capsules, and Queue Ribbon
local function drawCustomBuildCard(x, y, w, h, unitInfo, gf, uiScale)
    uiScale = uiScale or 1.0
    local unitDefID = unitInfo.unitDefID
    local def = UnitDefs and UnitDefs[unitDefID]
    local isBuilding = (not unitInfo.isQueued)
    local progress = max(0, min(1, unitInfo.progress or 0))

    -- Card Background
    glColor(0.04, 0.07, 0.10, 0.88)
    glRect(x, y, x + w, y + h)

    -- Card Border (Subtle cyan-gray glass frame)
    glColor(0.25, 0.45, 0.65, 0.65)
    glRect(x, y, x + w, y + 1)
    glRect(x, y + h - 1, x + w, y + h)
    glRect(x, y, x + 1, y + h)
    glRect(x + w - 1, y, x + w, y + h)

    -- Top title band
    local titleBandH = floor(28 * uiScale)
    local titleBandY = y + h - titleBandH - 2
    -- Top accent line
    glColor(0.40, 0.78, 0.98, 0.65)
    glRect(x + 2, y + h - 2, x + w - 2, y + h - 1)
    -- Bottom divider
    glColor(0.25, 0.48, 0.65, 0.45)
    glRect(x + 2, titleBandY, x + w - 2, titleBandY + 1)

    -- 1. Strategic Icon Box (SVG icon in top-left frame)
    local iconBoxSize = floor(24 * uiScale)
    local iconSize = floor(20 * uiScale)
    local iconBoxX = x + floor(6 * uiScale)
    local iconBoxY = titleBandY + (titleBandH - iconBoxSize) * 0.5
    glColor(0.35, 0.65, 0.85, 0.65)
    glRect(iconBoxX, iconBoxY, iconBoxX + iconBoxSize, iconBoxY + 1)
    glRect(iconBoxX, iconBoxY + iconBoxSize - 1, iconBoxX + iconBoxSize, iconBoxY + iconBoxSize)
    glRect(iconBoxX, iconBoxY, iconBoxX + 1, iconBoxY + iconBoxSize)
    glRect(iconBoxX + iconBoxSize - 1, iconBoxY, iconBoxX + iconBoxSize, iconBoxY + iconBoxSize)

    local iconX = iconBoxX + (iconBoxSize - iconSize) * 0.5
    local iconY = iconBoxY + (iconBoxSize - iconSize) * 0.5
    drawStrategicIcon(iconX, iconY, iconSize, unitDefID)

    -- 2. Unit Name Header (Clear, bold text right beside SVG icon)
    local title = def and (def.translatedHumanName or def.humanName or def.name) or "Unit"
    local titleX = iconBoxX + iconBoxSize + floor(7 * uiScale)
    local titleY = titleBandY + titleBandH * 0.5
    drawText(title, titleX, titleY, 15.0 * uiScale, {0.96, 0.98, 1.0, 1.0}, "vo")

    -- Bottom price band
    local priceBandH = floor(24 * uiScale)
    local priceBandY = y + floor(2 * uiScale)
    glColor(0.25, 0.48, 0.65, 0.45)
    glRect(x + 2, priceBandY + priceBandH - 1, x + w - 2, priceBandY + priceBandH)

    -- Middle 3D Model Area (Compact canvas)
    local modelX = x + floor(6 * uiScale)
    local modelY = y + priceBandH + floor(3 * uiScale)
    local modelW = w - floor(12 * uiScale)
    local modelH = h - titleBandH - priceBandH - floor(6 * uiScale)

    local drewModel = drawUnitModel(modelX, modelY, modelW, modelH, unitDefID)
    if not drewModel then
        glColor(1, 1, 1, 1)
        glTexture("#" .. unitDefID)
        glTexRect(modelX, modelY, modelX + modelW, modelY + modelH)
        glTexture(false)
    end

    -- 3. Floating Badges: Sub-Role (Left) and Tech Tier (Right)
    local badgeH = floor(16 * uiScale)
    local badgeY = priceBandY + priceBandH + floor(3 * uiScale)

    -- Sub-Role Badge Box & Text
    local role = unitRoleLabel(def)
    if role and role ~= "" then
        local roleColor = ROLE_COLORS[role] or {0.68, 0.84, 0.96, 1.0}
        local roleW = getTextPixelWidth(role, 9.5 * uiScale) + floor(14 * uiScale)
        local roleX = x + floor(6 * uiScale)
        -- Tint glow
        glColor(roleColor[1], roleColor[2], roleColor[3], 0.16)
        glRect(roleX + 1, badgeY + 1, roleX + roleW - 1, badgeY + badgeH - 1)
        -- 1px border
        glColor(roleColor[1], roleColor[2], roleColor[3], 0.75)
        glRect(roleX, badgeY, roleX + roleW, badgeY + 1)
        glRect(roleX, badgeY + badgeH - 1, roleX + roleW, badgeY + badgeH)
        glRect(roleX, badgeY, roleX + 1, badgeY + badgeH)
        glRect(roleX + roleW - 1, badgeY, roleX + roleW, badgeY + badgeH)
        -- Text
        drawText(role, roleX + roleW * 0.5, badgeY + badgeH * 0.5, 11.5 * uiScale, roleColor, "voco")
    end

    -- Tech Tier Badge Box & Text
    local tier = getTechTier(def)
    local tierColor = TIER_COLORS[tier] or TIER_COLORS[1]
    local tierW = floor(26 * uiScale)
    local tierX = x + w - tierW - floor(6 * uiScale)
    -- Tint glow
    glColor(tierColor[1], tierColor[2], tierColor[3], 0.18)
    glRect(tierX + 1, badgeY + 1, tierX + tierW - 1, badgeY + badgeH - 1)
    -- 1px border
    glColor(tierColor[1], tierColor[2], tierColor[3], 0.85)
    glRect(tierX, badgeY, tierX + tierW, badgeY + 1)
    glRect(tierX, badgeY + badgeH - 1, tierX + tierW, badgeY + badgeH)
    glRect(tierX, badgeY, tierX + 1, badgeY + badgeH)
    glRect(tierX + tierW - 1, badgeY, tierX + tierW, badgeY + badgeH)
    -- Text
    local tierStr = "T" .. tostring(tier)
    drawText(tierStr, tierX + tierW * 0.5, badgeY + badgeH * 0.5, 12.5 * uiScale, tierColor, "voco")

    -- 4. Price Capsules: Metal (Left) & Energy (Right)
    local pillPad = floor(4 * uiScale)
    local pillGap = floor(4 * uiScale)
    local totalPillSpace = (w - 4) - (pillPad * 2) - pillGap
    local pillW = totalPillSpace * 0.5
    local pillH = floor(20 * uiScale)
    local pillY = priceBandY + (priceBandH - pillH) * 0.5

    -- Metal Capsule
    local mX = x + 2 + pillPad
    local mY = pillY
    glColor(0.35, 0.70, 0.92, 0.12)
    glRect(mX + 1, mY + 1, mX + pillW - 1, mY + pillH - 1)
    glColor(0.35, 0.65, 0.85, 0.50)
    glRect(mX, mY, mX + pillW, mY + 1)
    glRect(mX, mY + pillH - 1, mX + pillW, mY + pillH)
    glRect(mX, mY, mX + 1, mY + pillH)
    glRect(mX + pillW - 1, mY, mX + pillW, mY + pillH)
    glColor(0.45, 0.85, 1.0, 0.90)
    glRect(mX + floor(2.5 * uiScale), mY + floor(3 * uiScale), mX + floor(5.5 * uiScale), mY + pillH - floor(3 * uiScale))
    local mCostStr = formatCost(def and def.metalCost or 0) .. " M"
    drawText(mCostStr, mX + pillW * 0.5 + 2, pillY + pillH * 0.5, 12.0 * uiScale, {0.90, 0.96, 1.0, 1.0}, "voco")

    -- Energy Capsule
    local eX = mX + pillW + pillGap
    local eY = pillY
    glColor(1.0, 0.80, 0.15, 0.12)
    glRect(eX + 1, eY + 1, eX + pillW - 1, eY + pillH - 1)
    glColor(0.85, 0.68, 0.18, 0.50)
    glRect(eX, eY, eX + pillW, eY + 1)
    glRect(eX, eY + pillH - 1, eX + pillW, eY + pillH)
    glRect(eX, eY, eX + 1, eY + pillH)
    glRect(eX + pillW - 1, eY, eX + pillW, eY + pillH)
    glColor(1.0, 0.85, 0.20, 0.90)
    glRect(eX + floor(2.5 * uiScale), eY + floor(3 * uiScale), eX + floor(5.5 * uiScale), eY + pillH - floor(3 * uiScale))
    local eCostStr = formatCost(def and def.energyCost or 0) .. " E"
    drawText(eCostStr, eX + pillW * 0.5 + 2, pillY + pillH * 0.5, 12.0 * uiScale, {1.0, 0.88, 0.22, 1.0}, "voco")

    -- 5. Queue / Progress Ribbon
    local ribbonH = floor(24 * uiScale)
    local ribbonY = y + (h - ribbonH) * 0.5 + floor(2 * uiScale)
    local ribbonX = x + floor(4 * uiScale)
    local ribbonW = w - floor(8 * uiScale)

    local countStr = tostring(unitInfo.count or 1)
    local centerLabel = ""
    local countColor = isBuilding and {0.20, 0.92, 0.45, 1.0} or {0.30, 0.70, 1.00, 1.0}

    if isBuilding then
        local state = etaState[unitInfo.unitID]
        if state and state.decaying and state.decayTime then
            centerLabel = sformat("STALL  x%s", countStr)
            countColor = {1.0, 0.25, 0.25, 1.0}
        elseif state and state.timeLeft then
            local secs = max(0, state.timeLeft)
            local m = floor(secs / 60)
            local s = floor(secs % 60)
            centerLabel = sformat("BUILDING x%s (%d:%02d)", countStr, m, s)
        else
            centerLabel = sformat("BUILDING  x%s", countStr)
        end
    else
        centerLabel = sformat("QUEUED  x%s", countStr)
    end

    local textCenterX = ribbonX + ribbonW * 0.5
    local textCenterY = ribbonY + ribbonH * 0.5
    local textSize = 13.5 * uiScale
    local splitX = ribbonX + ribbonW * progress

    -- Base unbuilt layer (Right)
    if isBuilding and progress > 0 and progress < 1 then
        glScissor(floor(splitX), floor(ribbonY), max(1, floor(ribbonX + ribbonW - splitX)), max(1, floor(ribbonH)))
    else
        glScissor(floor(ribbonX), floor(ribbonY), max(1, floor(ribbonW)), max(1, floor(ribbonH)))
    end

    -- Dark glass backing
    glColor(0.015, 0.035, 0.055, 0.75)
    glRect(ribbonX, ribbonY, ribbonX + ribbonW, ribbonY + ribbonH)
    -- Tinted glow
    glColor(countColor[1], countColor[2], countColor[3], 0.16)
    glRect(ribbonX + 1, ribbonY + 1, ribbonX + ribbonW - 1, ribbonY + ribbonH - 1)
    -- Top & bottom borders
    glColor(countColor[1], countColor[2], countColor[3], 0.70)
    glRect(ribbonX, ribbonY, ribbonX + ribbonW, ribbonY + 1)
    glRect(ribbonX, ribbonY + ribbonH - 1, ribbonX + ribbonW, ribbonY + ribbonH)
    drawText(centerLabel, textCenterX, textCenterY, textSize, countColor, "voco")
    glScissor(false)

    -- Built overlay layer (Left)
    if isBuilding and progress > 0 then
        local whiteW = ribbonW * progress
        glScissor(floor(ribbonX), floor(ribbonY), max(1, floor(whiteW)), max(1, floor(ribbonH)))

        -- Metallic slate-gray glass backing
        glColor(0.20, 0.26, 0.34, 0.70)
        glRect(ribbonX, ribbonY, ribbonX + ribbonW, ribbonY + ribbonH)
        -- Slate-gray inner highlight glow
        glColor(0.55, 0.65, 0.75, 0.20)
        glRect(ribbonX + 1, ribbonY + 1, ribbonX + ribbonW - 1, ribbonY + ribbonH - 1)
        -- Top & bottom crisp titanium borders
        glColor(0.70, 0.78, 0.86, 0.85)
        glRect(ribbonX, ribbonY, ribbonX + ribbonW, ribbonY + 1)
        glRect(ribbonX, ribbonY + ribbonH - 1, ribbonX + ribbonW, ribbonY + ribbonH)
        -- Left end cap
        glColor(0.75, 0.82, 0.90, 0.90)
        glRect(ribbonX, ribbonY, ribbonX + 3, ribbonY + ribbonH)
        drawText(centerLabel, textCenterX, textCenterY, textSize, {0.90, 0.94, 0.98, 1.0}, "voco")
        glScissor(false)

        -- Vertical Frontier Line (leading dividing line)
        if progress < 0.995 then
            glColor(0.92, 0.96, 1.00, 0.95)
            glRect(splitX - 1.5, ribbonY, splitX + 1.5, ribbonY + ribbonH)
            glColor(0.65, 0.75, 0.85, 0.30)
            glRect(splitX - 3.5, ribbonY, splitX + 3.5, ribbonY + ribbonH)
        end
    end
end

function widget:DrawScreen()
    if not config.show2DScreen then return end
    if #factoryUnits == 0 and #otherUnits == 0 then return end

    local vsx, vsy = spGetViewGeometry()
    local uiScale = getUIScale()
    local cardW = floor(BASE_CARD_WIDTH * uiScale)
    local cardH = floor(BASE_CARD_HEIGHT * uiScale)
    local rightMargin = floor(6 * uiScale)
    local topMargin = floor(36 * uiScale) + floor(vsy * 0.10) -- Shifted 10% lower down the screen
    local rowSpacing = floor(6 * uiScale)
    local colSpacing = floor(6 * uiScale)
    local bottomLimit = 180 -- Keeps clear of bottom-right player list

    local startX = vsx - rightMargin - cardW
    local startY = vsy - topMargin

    local maxRows = 5 -- Exactly 5 cards per column, wrapping to the next column on the left (red box)

    iconAreas = {}

    -- Clear depth buffer once before rendering 3D unit models
    if glUnitShape and GL_DEPTH_BUFFER_BIT then
        glClear(GL_DEPTH_BUFFER_BIT)
    end

    local allCards = {}
    for i = 1, #factoryUnits do allCards[#allCards + 1] = factoryUnits[i] end
    for i = 1, #otherUnits do allCards[#allCards + 1] = otherUnits[i] end

    local gf = spGetGameFrame()

    for i = 1, #allCards do
        local unitInfo = allCards[i]
        local col = floor((i - 1) / maxRows)
        local row = (i - 1) % maxRows
        local x = startX - col * (cardW + colSpacing)
        local y = startY - (row + 1) * (cardH + rowSpacing) + rowSpacing

        drawCustomBuildCard(x, y, cardW, cardH, unitInfo, gf, uiScale)
        iconAreas[#iconAreas + 1] = {
            x1 = x,
            y1 = y,
            x2 = x + cardW,
            y2 = y + cardH,
            unitID = unitInfo.unitID,
            unitInfo = unitInfo,
        }
    end

    glColor(1, 1, 1, 1)
end

local function isInRect(x, y, rect)
    return x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y <= rect.y2
end

function widget:MousePress(x, y, button)
    if button == 1 then
        for i = 1, #iconAreas do
            local area = iconAreas[i]
            if isInRect(x, y, area) then
                local uID = area.unitInfo and (area.unitInfo.facID or area.unitID) or area.unitID
                local ux, uy, uz = spGetUnitPosition(uID)
                if ux then
                    spSetCameraTarget(ux, uy, uz)
                    return true
                end
            end
        end
    end
    return false
end

function widget:GetConfigData()
    return config
end

function widget:SetConfigData(data)
    if type(data) == "table" then
        for k, v in pairs(data) do
            if config[k] ~= nil then config[k] = v end
        end
    end
end