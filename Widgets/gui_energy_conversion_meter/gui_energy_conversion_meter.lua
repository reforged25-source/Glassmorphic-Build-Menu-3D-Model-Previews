local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Energy Conversion Meter",
        desc = "9-bar meter next to the top bar showing your energy<->converter balance: green center = balanced, bars ramp yellow -> red as the imbalance grows. Right = energy going unconverted (Overflowing), left = converter capacity starved (Idle converters). Severity is relative to your E income; shows the E/s value, plus a small hint text at 3+ bars. Energy/converters actively under construction already count as fixed (blueprints don't). Holding 3+ bars for ~5s pops an on-screen alert; pinned at 4 bars it repeats every 20s and the side icon pulses red. Alerts are configurable in Settings > Custom (on/off, spectating, size, sound). Ctrl + left-click drag repositions the meter (saved).",
        author = "Egzothicki",
        date = "July 2026",
        license = "GNU GPL, v2 or later",
        layer = 100,
        enabled = true,
    }
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local SIZE_FRAC = 0.98 -- meter height as fraction of top bar height
local ANCHOR_MARGIN = 12 -- default-position gap after the top bar's last element

local CONV_EXCESS_MIN = 70 -- E/s of net income before the excess side shows
local CONV_DEFICIT_MIN = 70 -- E/s of idle capacity before the deficit side shows
-- meter severity is RELATIVE to current E income (3k excess on 5k income = huge,
-- on 100k income = mild). Level 1 = any qualifying amount, then:
local CONV_RATIO_TIERS = { 0.10, 0.30, 0.60 } -- value/income fractions for levels 2..4
-- ...but a huge ABSOLUTE amount is severe even on a huge income (120k excess on
-- 400k income is 20 epic converters, not "2 bars") — level is the max of both.
-- Floors are per-side, equalized by METAL COST TO FIX (~4k/10k/19k M): fixing
-- 1 E/s of deficit with afus (9700M/3000E) costs ~5x more than with adv
-- converters (380M/600E), so the deficit floors are ~5x lower:
local CONV_ABS_TIERS_EXCESS = { 6000, 15000, 30000 } -- E/s floors, levels 2..4
local CONV_ABS_TIERS_DEFICIT = { 1200, 3000, 6000 }
local CONV_ALPHA = 0.22 -- EMA weight per 0.5s poll (~2s time constant)
local CONV_STABLE_TICKS = 3 -- polls a mode must hold before the display switches
-- Colors: the meter shows IMBALANCE, not sides — green center = balanced, then
-- a traffic-light ramp outward on BOTH sides. Which side tells you WHAT to add
-- (direction, end icons, text); color only tells you HOW BAD.
local CONV_OK_COLOR = { 0.35, 1.0, 0.45 } -- center bar while balanced
local CONV_NEUTRAL_COLOR = { 0.95, 0.95, 0.95 } -- value text while balanced (like the stored-amount numbers)
local CONV_BAR_COLORS = { -- by bar position 1..4, either side
    { 1.0, 0.85, 0.15 }, -- 1: yellow
    { 1.0, 0.60, 0.10 }, -- 2: orange
    { 1.0, 0.33, 0.08 }, -- 3: orange-red (alert territory starts here)
    { 1.0, 0.12, 0.08 }, -- 4: red
}
-- Sustained-severity notifications: the meter can bounce even -4 -> +4 during
-- building bursts, so a level only alerts after it HOLDS. |level| >= 3 held for
-- CONV_NOTIF_SUSTAIN fires one notification per episode (re-arms once it drops
-- below 3); |level| = 4 held fires a stronger pulsing one that repeats every
-- CONV_NOTIF4_REPEAT while it stays pinned. A side flip resets the timers.
local CONV_NOTIF_SUSTAIN = 4.5 -- seconds a level must hold before it alerts
local CONV_NOTIF4_REPEAT = 20 -- seconds between repeats while pinned at 4
local CONV_NOTIF_COOLDOWN = 30 -- min seconds between level-3 alerts (2<->3 bounce guard)
local CONV_NOTIF_SECONDS = 4 -- level-3 notification hold time
local CONV_NOTIF4_SECONDS = 6 -- level-4 notification hold time
local CONV_NOTIF_SIZES = { -- notification font size at 1080p: { level-4 strong, level-3 mild }
    Large = { 26, 19 },
    Medium = { 20, 15 },
    Small = { 15, 11 },
}
-- an eco construction still counts as "being built" this many seconds after its
-- last build progress (rides builder swaps / short stalls); an untouched
-- blueprint never gets progress, so it never counts
local BUILD_ACTIVE_GRACE = 3

--------------------------------------------------------------------------------
-- User settings (Settings > Custom > Energy Conversion Meter)
--------------------------------------------------------------------------------
local config = {
    notifEnabled = true, -- pop the on-screen alert at sustained 3+ bars
    notifSpectating = false, -- also alert while spectating
    notifSize = "Medium", -- Large / Medium / Small (CONV_NOTIF_SIZES keys)
    notifSound = true, -- beep when an alert fires
}

local OPTION_SPECS = {
    {
        configVariable = "notifEnabled",
        name = "Notify when Idle Converters / Overflowing",
        description = "Pop up the on-screen alert when the meter holds 3+ bars of Overflowing or Idle converters.\nThe meter itself always stays visible.",
        type = "bool",
    },
    {
        configVariable = "notifSpectating",
        name = "Show notification when spectating",
        description = "Also pop up alerts for the team you are watching while spectating.",
        type = "bool",
    },
    {
        configVariable = "notifSize",
        name = "Notification size",
        description = "Size of the on-screen alert text.",
        type = "select",
        options = { "Large", "Medium", "Small" },
    },
    {
        configVariable = "notifSound",
        name = "Notification sound",
        description = "Play a beep when an alert fires.",
        type = "bool",
    },
}

local function GetOptionId(spec)
    return "energy_conv_meter__" .. spec.configVariable
end

-- the options menu wants selects as an index into spec.options; config stores the string
local function GetOptionValue(spec)
    if spec.type == "select" then
        for i, v in ipairs(spec.options) do
            if config[spec.configVariable] == v then return i end
        end
        return 1
    end
    return config[spec.configVariable]
end

local function SetOptionValue(spec, value)
    if spec.type == "select" then
        config[spec.configVariable] = spec.options[value] or config[spec.configVariable]
    else
        config[spec.configVariable] = value
    end
end

local function RegisterOptions()
    if not (WG['options'] and WG['options'].addOptions) then return end
    local list = {}
    for _, spec in ipairs(OPTION_SPECS) do
        list[#list + 1] = {
            id = GetOptionId(spec),
            widgetname = "Energy Conversion Meter",
            name = spec.name,
            description = spec.description,
            type = spec.type,
            options = spec.options,
            value = GetOptionValue(spec),
            onchange = function(_, value)
                SetOptionValue(spec, value)
            end,
        }
    end
    WG['options'].addOptions(list)
end

local function UnregisterOptions()
    if not (WG['options'] and WG['options'].removeOptions) then return end
    local ids = {}
    for _, spec in ipairs(OPTION_SPECS) do
        ids[#ids + 1] = GetOptionId(spec)
    end
    WG['options'].removeOptions(ids)
end

--------------------------------------------------------------------------------
local glColor = gl.Color
local glRect = gl.Rect
local glText = gl.Text
local glTexture = gl.Texture
local glTexRect = gl.TexRect

local vsx, vsy = 1920, 1080
local convText, convColor = nil, CONV_BAR_COLORS[1] -- value line ("+3k")
local convAction = nil -- hint text below, smaller ("Overflowing"/"Idle converters"), only shown at |level| >= 3
local convLevel = 0 -- meter position: -4 (converters starved) .. +4 (energy unconverted)
local convPos = { x = -9999, y = 0, s = 34, w = 0 }
local convDrag = nil -- {grabDX, grabDY} while the meter is being Ctrl-dragged
local convUserPos = nil -- {xFrac, yFrac} user-chosen position (screen fractions, saved); nil = auto
local emaInc, emaExp, emaUse
local convMode, convCandidate, convTicks = nil, nil, 0
local sinceRefresh = 1
local convNotifText, convNotifUntil, convNotifStrong, convNotifColor = nil, 0, false, nil
local conv3Since, conv4Since = nil, nil -- os.clock() when |level| continuously reached 3 / 4
local convSide = 0 -- sign of the level the sustain timers are tracking
local conv3Fired = false -- level-3 alert already fired this episode
local conv3LastAt, conv4LastAt = -999, -999
-- bar-4 pulse for the pinned side's icon + the action label: same blink shape as
-- gui_top_bar's overflow flash (fast dt*9 attack, eased ~0.75s decay, ~0.86s/cycle)
local convBlink, convBlinkDir = 0, true

-- end-cap icons mark the PROBLEM side: converter map icon on the Idle
-- converters side (left), lightning bolt (the top bar's own energy icon) on
-- the Overflowing side (right); buildpic fallback if the icontypes lookup fails
local convEnergyIcon = ":l:LuaUI/Images/energy.png"
local convMakerIcon
do
    local ok, iconTypes = pcall(VFS.Include, "gamedata/icontypes.lua")
    local function iconOf(name)
        local ud = UnitDefNames[name]
        if not ud then return nil end
        local it = ok and iconTypes and ud.iconType and iconTypes[ud.iconType]
        return (it and it.bitmap and (":l:" .. it.bitmap)) or ("#" .. ud.id)
    end
    convMakerIcon = iconOf("armmakr") or iconOf("cormakr")
end

-- eco under construction: if the user is already ACTIVELY building energy (or
-- converters), don't nag them to add more — the finished output of actively-
-- built sites is deducted from the deficit (or excess) before the meter/alerts
-- see it. "Actively" = build progress advanced within BUILD_ACTIVE_GRACE; a
-- placed-but-untouched blueprint never counts.
local convCapOf = {} -- unitDefID -> converter capacity once finished
local energyOutOf = {} -- unitDefID -> E/s once finished (immobile producers)
local ecoDefIDList = {} -- both of the above, for GetTeamUnitsByDefs
local buildTrack = {} -- under-construction eco unitID -> { p = progress, at = last progress time }

local function BuildEcoDefs()
    local avgWind = ((Game.windMin or 0) + (Game.windMax or 0)) * 0.5
    local tidal = Game.tidal or 0
    for udid, ud in pairs(UnitDefs) do
        local cp = ud.customParams
        local cap = cp and tonumber(cp.energyconv_capacity)
        if cap and cap > 0 then
            convCapOf[udid] = cap
            ecoDefIDList[#ecoDefIDList + 1] = udid
        elseif ud.isImmobile then
            -- solars produce via NEGATIVE energyUpkeep (so they can be toggled off)
            local e = (ud.energyMake or 0) + math.max(0, -(ud.energyUpkeep or 0))
            if (ud.windGenerator or 0) > 0 then
                e = e + math.min(avgWind, ud.windGenerator)
            end
            e = e + (ud.tidalGenerator or 0) * tidal
            if e >= 15 then
                energyOutOf[udid] = e
                ecoDefIDList[#ecoDefIDList + 1] = udid
            end
        end
    end
end

-- finished E/s + converter capacity of eco sites actively being built
local function PendingEcoRates()
    local now = os.clock()
    local pendE, pendCap = 0, 0
    local units = Spring.GetTeamUnitsByDefs(Spring.GetMyTeamID(), ecoDefIDList)
    local seen = {}
    for i = 1, #units do
        local uid = units[i]
        if Spring.GetUnitIsBeingBuilt(uid) then
            seen[uid] = true
            local progress = select(5, Spring.GetUnitHealth(uid)) or 0
            local tr = buildTrack[uid]
            if not tr then
                tr = { p = progress, at = -999 }
                buildTrack[uid] = tr
            elseif progress > tr.p + 1e-4 then
                tr.p = progress
                tr.at = now
            end
            if now - tr.at <= BUILD_ACTIVE_GRACE then
                local did = Spring.GetUnitDefID(uid)
                pendE = pendE + (energyOutOf[did] or 0)
                pendCap = pendCap + (convCapOf[did] or 0)
            end
        end
    end
    for uid in pairs(buildTrack) do
        if not seen[uid] then buildTrack[uid] = nil end
    end
    return pendE, pendCap
end

-- the top bar's short() format: <= 9999 plain (with comma), then k / m — bounded length,
-- so the value slot can reserve a constant width and never jump
local function FormatE(v)
    v = math.floor(v)
    if v > 9999999 then
        return string.format("%.0fm", v / 1000000)
    elseif v > 9999 then
        return string.format("%.0fk", v / 1000)
    end
    local s = tostring(v)
    if #s >= 4 then
        s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    end
    return s
end

local function TierLevel(v, income, absTiers)
    local ratio = v / math.max(income or 0, 1)
    local lvl = 1 -- reaching the meter at all = at least mild
    for i = 1, #CONV_RATIO_TIERS do
        if ratio >= CONV_RATIO_TIERS[i] then lvl = i + 1 end
    end
    for i = 1, #absTiers do
        if v >= absTiers[i] and (i + 1) > lvl then lvl = i + 1 end
    end
    return lvl
end

local function UpdateConversionInfo()
    local teamID = Spring.GetMyTeamID()
    local _, _, _, eInc, eExp = Spring.GetTeamResources(teamID, "energy")
    if not eInc then
        convText, convAction, convLevel = nil, nil, 0
        return
    end
    -- mmUse/mmCapacity: set by the game's energy conversion gadget (same source
    -- the top bar uses) — actual converted E/s and total converter capacity
    local mmUse = Spring.GetTeamRulesParam(teamID, "mmUse") or 0
    local mmCap = Spring.GetTeamRulesParam(teamID, "mmCapacity") or 0
    emaInc = emaInc and (emaInc + CONV_ALPHA * (eInc - emaInc)) or eInc
    emaExp = emaExp and (emaExp + CONV_ALPHA * (eExp - emaExp)) or eExp
    emaUse = emaUse and (emaUse + CONV_ALPHA * (mmUse - emaUse)) or mmUse

    local net = emaInc - emaExp
    local idle = mmCap - emaUse
    -- eco already being built counts as handled: actively-built converters will
    -- absorb the excess, actively-built energy will feed the idle converters
    local pendE, pendCap = PendingEcoRates()
    net = net - pendCap
    idle = idle - pendE
    -- always-visible value: the dominant imbalance, signed like the meter sides
    -- (shown even at green/balanced so the number is a permanent fixture)
    local dom = (net >= idle) and math.max(0, net) or -math.max(0, idle)
    if dom > -1 and dom < 1 then
        convText = "0"
    else
        convText = (dom > 0 and "+" or "-") .. FormatE(math.abs(dom))
    end

    -- excess only counts when existing converters are already ~saturated (else the
    -- conversion gadget will absorb it by itself once storage passes the slider level);
    -- expense already includes conversion drain, so positive net = true overflow
    local mode
    if net >= CONV_EXCESS_MIN and (mmCap <= 0 or emaUse >= 0.9 * mmCap) then
        mode = "excess"
    elseif idle >= CONV_DEFICIT_MIN then
        mode = "deficit"
    end

    -- mode hysteresis: hold CONV_STABLE_TICKS polls before the display flips
    if mode ~= convCandidate then
        convCandidate, convTicks = mode, 1
    else
        convTicks = convTicks + 1
    end
    if convTicks >= CONV_STABLE_TICKS then
        convMode = mode
    end

    if convMode == nil or convMode ~= mode then
        if convMode == nil then
            convAction, convLevel = nil, 0
            convColor = CONV_NEUTRAL_COLOR
        end
        return -- keep last display (except the live value) while a flip is pending
    end

    if convMode == "excess" then
        convText = "+" .. FormatE(net)
        convLevel = TierLevel(net, emaInc, CONV_ABS_TIERS_EXCESS)
        convColor = CONV_BAR_COLORS[convLevel]
        convAction = convLevel >= 3 and "Overflowing" or nil
    else
        convText = "-" .. FormatE(idle)
        convLevel = -TierLevel(idle, emaInc, CONV_ABS_TIERS_DEFICIT)
        convColor = CONV_BAR_COLORS[-convLevel]
        convAction = convLevel <= -3 and "Idle converters" or nil
    end
end

-- runs on the same 0.5s poll as UpdateConversionInfo, on the DISPLAYED level
-- (post-EMA, post-hysteresis) — what the user sees is what gets timed
local function UpdateConvNotify()
    -- alerts off (globally, or while spectating): drop any pending episode so
    -- re-enabling mid-game starts a fresh sustain window instead of firing at once
    if not config.notifEnabled
        or (Spring.GetSpectatingState() and not config.notifSpectating) then
        conv3Since, conv4Since, conv3Fired, convSide = nil, nil, false, 0
        return
    end
    local now = os.clock()
    local side = (convLevel > 0 and 1) or (convLevel < 0 and -1) or 0
    if side ~= convSide or math.abs(convLevel) < 3 then
        conv3Since, conv4Since, conv3Fired = nil, nil, false
        convSide = side
        return
    end
    conv3Since = conv3Since or now
    if math.abs(convLevel) >= 4 then
        conv4Since = conv4Since or now
    else
        conv4Since = nil
    end

    local excess = side > 0
    if conv4Since and (now - conv4Since) >= CONV_NOTIF_SUSTAIN
        and (now - conv4LastAt) >= CONV_NOTIF4_REPEAT then
        conv4LastAt = now
        conv3Fired = true -- the strong alert covers the mild one
        convNotifText = (convText and (convText .. "  ") or "")
            .. (excess and "OVERFLOWING" or "IDLE CONVERTERS")
        convNotifStrong = true
        convNotifUntil = now + CONV_NOTIF4_SECONDS
        convNotifColor = convColor
        if config.notifSound then
            Spring.PlaySoundFile("beep4", 0.75, "ui")
        end
    elseif not conv3Fired and (now - conv3Since) >= CONV_NOTIF_SUSTAIN
        and (now - conv3LastAt) >= CONV_NOTIF_COOLDOWN then
        conv3Fired = true
        conv3LastAt = now
        convNotifText = (convText and (convText .. "  ") or "")
            .. (excess and "OVERFLOWING" or "IDLE CONVERTERS")
        convNotifStrong = false
        convNotifUntil = now + CONV_NOTIF_SECONDS
        convNotifColor = convColor
        if config.notifSound then
            Spring.PlaySoundFile("beep4", 0.35, "ui")
        end
    end
end

-- magnet snapping while Ctrl-dragging: edges stick to other snap-aware widgets
-- (WG.snapRects peers), the minimap and the top bar when within SNAP_DIST px;
-- side-by-side placement uses a SNAP_GAP gutter to match the button rows
local SNAP_KEY = 'energyconvmeter'
local SNAP_DIST = 10 -- px within which an edge snaps
local SNAP_GAP = 5 -- gutter when sticking next to something
local SNAP_NEAR = 40 -- only snap an axis when the other axis roughly overlaps
local SNAP_GRID = 16 -- fallback grid spacing when nothing else catches an axis

local function SnapPos(x, y, w, h)
    local rects = {}
    if WG.snapRects then
        for k, r in pairs(WG.snapRects) do
            if k ~= SNAP_KEY then rects[#rects + 1] = r end
        end
    end
    local mpx, mpy, msx, msy = Spring.GetMiniMapGeometry()
    if msx and msx > 0 then rects[#rects + 1] = { mpx, mpy, mpx + msx, mpy + msy } end
    local tb = WG['topbar'] and WG['topbar'].GetPosition and WG['topbar'].GetPosition()
    if tb then rects[#rects + 1] = { tb[1], tb[2], math.min(tb[3] or vsx, vsx), vsy } end

    local bestDX, bestDY
    for i = 1, #rects do
        local r = rects[i]
        if y < r[4] + SNAP_NEAR and y + h > r[2] - SNAP_NEAR then
            local cands = { r[1], r[3] - w, r[3] + SNAP_GAP, r[1] - w - SNAP_GAP }
            for j = 1, 4 do
                local d = cands[j] - x
                if math.abs(d) <= SNAP_DIST and (not bestDX or math.abs(d) < math.abs(bestDX)) then bestDX = d end
            end
        end
        if x < r[3] + SNAP_NEAR and x + w > r[1] - SNAP_NEAR then
            local cands = { r[2], r[4] - h, r[4] + SNAP_GAP, r[2] - h - SNAP_GAP }
            for j = 1, 4 do
                local d = cands[j] - y
                if math.abs(d) <= SNAP_DIST and (not bestDY or math.abs(d) < math.abs(bestDY)) then bestDY = d end
            end
        end
    end
    -- dense-net fallback per axis: free placements still stick to a grid
    if not bestDX then bestDX = math.floor(x / SNAP_GRID + 0.5) * SNAP_GRID - x end
    if not bestDY then bestDY = math.floor(y / SNAP_GRID + 0.5) * SNAP_GRID - y end
    return x + bestDX, y + bestDY
end

local function UpdatePos()
    local tb = WG['topbar'] and WG['topbar'].GetPosition and WG['topbar'].GetPosition()
    local free = WG['topbar'] and WG['topbar'].GetFreeArea and WG['topbar'].GetFreeArea()
    if tb and free then
        local h = vsy - tb[2]
        convPos.s = math.floor(h * SIZE_FRAC)
        convPos.y = math.floor(tb[2] + (h - convPos.s) * 0.5)
        -- anchor after the LAST thing that actually draws in the bar's free-area
        -- tail: the stock Converter Usage box (it publishes its rect; zero rect
        -- while hidden = no converters yet)
        local baseX = free[1]
        local cu = WG['converter_usage'] and WG['converter_usage'].GetPosition and WG['converter_usage'].GetPosition()
        if cu and cu[3] and cu[3] > baseX then
            baseX = cu[3]
        end
        convPos.x = math.floor(baseX + ANCHOR_MARGIN)
    else
        convPos.s = math.floor(34 * math.max(0.7, vsy / 1080))
        convPos.y = vsy - convPos.s - 4
        convPos.x = math.floor(vsx * 0.72)
    end

    -- user-dragged position override (Ctrl+drag), stored as screen fractions
    if convUserPos then
        local w = convPos.w > 0 and convPos.w or 200
        convPos.x = math.floor(math.max(0, math.min(convUserPos[1] * vsx, vsx - w)))
        convPos.y = math.floor(math.max(0, math.min(convUserPos[2] * vsy, vsy - convPos.s)))
    end
end

function widget:ViewResize(x, y)
    vsx, vsy = x, y
    UpdatePos()
end

function widget:Initialize()
    BuildEcoDefs()
    RegisterOptions()
    local x, y = Spring.GetViewGeometry()
    widget:ViewResize(x, y)
    UpdateConversionInfo()
end

function widget:PlayerChanged()
    emaInc, emaExp, emaUse = nil, nil, nil
    convMode, convCandidate, convTicks = nil, nil, 0
    convText, convAction, convLevel = nil, nil, 0
    convNotifText, conv3Since, conv4Since, convSide, conv3Fired = nil, nil, nil, 0, false
    buildTrack = {}
end

function widget:Update(dt)
    sinceRefresh = sinceRefresh + dt
    if sinceRefresh > 0.5 then
        sinceRefresh = 0
        UpdateConversionInfo()
        UpdateConvNotify()
    end

    -- drive the bar-4 red pulse (blink shape copied from gui_top_bar)
    if convLevel >= 4 or convLevel <= -4 then
        if convBlinkDir then
            convBlink = convBlink + (dt * 9)
            if convBlink > 1 then
                convBlink = 1
                convBlinkDir = false
            end
        else
            convBlink = convBlink - (dt / (convBlink * 1.5))
            if convBlink < 0 then
                convBlink = 0
                convBlinkDir = true
            end
        end
    elseif convBlink ~= 0 then
        convBlink, convBlinkDir = 0, true -- re-arm so each episode opens with the attack ramp
    end
end

local CONV_TIP_TITLE = "Energy Conversion Meter"
local function ConvTooltipText()
    return "Shows how much out of balance you are in Energy Conversion"
        .. " (Overflowing vs Idle Converters). Ctrl + left mouse click to drag it"
end

function widget:DrawScreen()
    if Spring.IsGUIHidden() then return end
    UpdatePos()

    -- 9 vertical bars, -4 (left: converters starved) .. 0 (center, green when
    -- balanced) .. +4 (right: energy going unconverted), traffic-light severity
    -- ramp, on a FlowUI panel
    local s = convPos.s
    local hasAction = convAction ~= nil
    local barW = math.max(3, math.floor(s * 0.10))
    local barGap = math.max(2, math.floor(s * 0.055))
    local pad = math.max(6, math.floor(s * 0.20))
    local totalW = 9 * barW + 8 * barGap
    local fs = hasAction and (s * 0.31) or (s * 0.35)
    local fs2 = s * 0.23
    local textGap = math.max(6, math.floor(s * 0.18))
    -- top bar's font (Exo2) for the value + banner, glText fallback
    local f2 = WG['fonts'] and WG['fonts'].getFont and WG['fonts'].getFont(2)
    -- value slot reserves the widest possible short()-formatted value
    -- ("+99,999k") so the panel width never jumps as the number changes
    local textW = 0
    if convText then
        local sampleW = (f2 and f2:GetTextWidth("+99,999k")) or gl.GetTextWidth("+99,999k") or 0
        local curW = (f2 and f2:GetTextWidth(convText)) or gl.GetTextWidth(convText) or 0
        textW = math.ceil(math.max(sampleW, curW) * fs)
    end
    local actionW = hasAction and math.ceil(((f2 and f2:GetTextWidth(convAction)) or gl.GetTextWidth(convAction) or 0) * fs2) or 0
    local iconS = hasAction and math.floor(s * 0.38) or math.floor(s * 0.44)
    local iconGap = math.max(5, math.floor(s * 0.16))
    -- converter icon left (Idle converters side), energy bolt right (Overflowing side)
    local leftIcon, rightIcon = convMakerIcon, convEnergyIcon
    local iconsW = (leftIcon and (iconS + iconGap) or 0) + (rightIcon and (iconGap + iconS) or 0)
    -- top-bar style: same 20-degree trapezoid skew, wide top / narrow bottom
    -- ("\  /"); the bottom cut eats into the sides, so pad the content extra
    local sk = WG['topbar'] and WG['topbar'].GetSkewConfig and WG['topbar'].GetSkewConfig()
    local skew = (sk and sk.useSkew) and { blx = s * sk.skewTan, brx = -(s * sk.skewTan) } or nil
    local sidePad = skew and math.ceil(s * sk.skewTan * 0.95) or math.floor(s * 0.08)
    local rowW = iconsW + totalW + (convText and (textGap + textW) or 0)
    local contentW = math.max(rowW, actionW)
    local panelW = pad + sidePad + contentW + sidePad + pad
    local x1, y1 = convPos.x, convPos.y
    local fui = WG.FlowUI and WG.FlowUI.Draw
    if fui and fui.Element then
        -- the top bar's own element style (incl. its opacity setting)
        fui.Element(x1, y1, x1 + panelW, y1 + s, 1, 1, 1, 1, 1, 1, 1, 1, nil, nil, nil, nil, nil, skew)
    elseif fui and fui.RectRound then
        fui.RectRound(x1, y1, x1 + panelW, y1 + s, math.floor(s * 0.16), 1, 1, 1, 1,
            { 0, 0, 0, 0.62 }, { 0.14, 0.14, 0.14, 0.62 })
    else
        glColor(0, 0, 0, 0.55)
        glRect(x1, y1, x1 + panelW, y1 + s)
    end

    -- bar-4 alert: the top bar's exact "wasting" flash — additive red over the
    -- whole element, alpha 0.1 * blink
    if (convLevel >= 4 or convLevel <= -4) and fui and fui.RectRound then
        gl.Blending(GL.SRC_ALPHA, GL.ONE)
        local cs = (WG.FlowUI and WG.FlowUI.elementCorner) or math.floor(s * 0.16)
        local fc = { 1, 0, 0, 0.1 * convBlink }
        if skew and fui.RectRoundQuad then
            fui.RectRoundQuad(x1, y1, x1 + panelW, y1 + s, cs, 1, 1, 1, 1, fc, fc, skew)
        else
            fui.RectRound(x1, y1, x1 + panelW, y1 + s, cs, 1, 1, 1, 1, fc, fc)
        end
        gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
    end
    -- top line: [E icon] bars [conv icon] + value; bottom line: action, smaller
    local cyMid = hasAction and (y1 + s * 0.65) or (y1 + s * 0.50)
    local barMult = hasAction and 0.70 or 1.0
    local rowOffset = math.floor((contentW - rowW) * 0.5)
    local rowStartX = x1 + pad + sidePad + rowOffset
    local barsX = rowStartX + (leftIcon and (iconS + iconGap) or 0)
    for i = -4, 4 do
        local bx = barsX + (i + 4) * (barW + barGap)
        local bh = barMult * s * (0.18 + 0.085 * math.abs(i))
        local filled = (convLevel > 0 and i > 0 and i <= convLevel)
            or (convLevel < 0 and i < 0 and i >= convLevel)
        if i == 0 then
            if convLevel == 0 then
                glColor(CONV_OK_COLOR[1], CONV_OK_COLOR[2], CONV_OK_COLOR[3], 0.9)
            else
                glColor(0.85, 0.85, 0.85, 0.45)
            end
        elseif filled then
            local c = CONV_BAR_COLORS[math.abs(i)] -- severity ramp
            glColor(c[1], c[2], c[3], 0.95)
        else
            glColor(0.55, 0.55, 0.55, 0.25)
        end
        glRect(bx, cyMid - bh * 0.5, bx + barW, cyMid + bh * 0.5)
    end
    if leftIcon then
        if convLevel <= -4 then
            glColor(1, 0.16, 0.12, 0.35 + 0.65 * convBlink) -- bar 4 hit: pulsing red
        else
            glColor(0.85, 0.85, 0.85, 0.9) -- neutral: color means severity only
        end
        glTexture(leftIcon)
        glTexRect(rowStartX, cyMid - iconS * 0.5, rowStartX + iconS, cyMid + iconS * 0.5)
        glTexture(false)
    end
    if rightIcon then
        if convLevel >= 4 then
            glColor(1, 0.16, 0.12, 0.35 + 0.65 * convBlink) -- bar 4 hit: pulsing red
        else
            glColor(0.85, 0.85, 0.85, 0.9) -- neutral: color means severity only
        end
        glTexture(rightIcon)
        local ix = barsX + totalW + iconGap
        glTexRect(ix, cyMid - iconS * 0.5, ix + iconS, cyMid + iconS * 0.5)
        glTexture(false)
    end
    if convText then
        -- value in the top bar's stored-amount style: Exo2 font, outlined
        local textX = barsX + totalW + (rightIcon and (iconGap + iconS) or 0) + textGap
        if f2 then
            f2:Begin()
            f2:SetTextColor(convColor[1], convColor[2], convColor[3], 0.95)
            f2:SetOutlineColor(0, 0, 0, 1)
            f2:Print(convText, textX, cyMid - fs * 0.36, fs, "o")
            f2:End()
        else
            glColor(convColor[1], convColor[2], convColor[3], 0.95)
            glText(convText, textX, cyMid - fs * 0.36, fs, "o")
        end
    end
    if convAction then
        -- plain hint text, no banner backdrop; always the top bar's
        -- "Overflowing" yellow (never the red "Wasting" set), never pulsing
        local bcx = math.floor(x1 + panelW * 0.5)
        if f2 then
            f2:Begin()
            f2:SetTextColor(1, 0.88, 0, 0.95)
            f2:SetOutlineColor(0.25, 0.16, 0, 0.6)
            f2:Print(convAction, bcx, y1 + math.floor(s * 0.17), fs2, "oc")
            f2:End()
        else
            glColor(1, 0.88, 0, 0.95)
            glText(convAction, bcx, y1 + math.floor(s * 0.16), fs2, "oc")
        end
    end
    convPos.w = panelW
    WG.snapRects = WG.snapRects or {}
    WG.snapRects[SNAP_KEY] = { convPos.x, convPos.y, convPos.x + panelW, convPos.y + s }

    -- hover tooltip goes through BAR's tooltip widget (the engine GetTooltip
    -- callin is not rendered as a cursor tooltip); area refreshed every frame
    if WG['tooltip'] and WG['tooltip'].AddTooltip and convPos.w > 0 then
        WG['tooltip'].AddTooltip('energyconvmeter',
            { convPos.x, convPos.y, convPos.x + convPos.w, convPos.y + convPos.s },
            ConvTooltipText(), nil, CONV_TIP_TITLE)
    end

    -- sustained-severity notification, side-colored, upper-center;
    -- level 4 = bigger and pulsing, level 3 = steady and smaller
    -- (gated on the setting too, so toggling it off hides an active one at once)
    if config.notifEnabled and convNotifText and os.clock() < convNotifUntil then
        local c = convNotifColor or CONV_BAR_COLORS[4]
        local a = 0.9
        if convNotifStrong then
            local pulse = 0.5 + 0.5 * math.sin(os.clock() * 2 * math.pi * 1.6)
            a = 0.55 + 0.45 * pulse
        end
        local sizes = CONV_NOTIF_SIZES[config.notifSize] or CONV_NOTIF_SIZES.Medium
        local nscale = math.max(0.7, vsy / 1080)
        glColor(c[1], c[2], c[3], a)
        glText(convNotifText, vsx * 0.5, vsy * 0.74,
            math.floor((convNotifStrong and sizes[1] or sizes[2]) * nscale), "oc")
    end
    glColor(1, 1, 1, 1)
end

function widget:IsAbove(mx, my)
    -- tooltip + Ctrl-drag; plain clicks still pass through (MousePress only
    -- grabs the panel when Ctrl is held)
    return convPos.w > 0 and mx >= convPos.x and mx <= convPos.x + convPos.w
        and my >= convPos.y and my <= convPos.y + convPos.s
end

function widget:MousePress(mx, my, button)
    if button ~= 1 or Spring.IsGUIHidden() then return false end
    if self:IsAbove(mx, my) then
        local _, ctrl = Spring.GetModKeyState()
        if ctrl then
            convDrag = { mx - convPos.x, my - convPos.y }
            return true
        end
    end
    return false
end

function widget:MouseMove(mx, my)
    if convDrag then
        local x, y = SnapPos(mx - convDrag[1], my - convDrag[2],
            convPos.w > 0 and convPos.w or 200, convPos.s)
        convUserPos = { x / vsx, y / vsy }
        return true
    end
end

function widget:MouseRelease(mx, my, button)
    if convDrag then
        convDrag = nil
    end
    return false
end

function widget:GetConfigData()
    local data = { convUserPos = convUserPos }
    for _, spec in ipairs(OPTION_SPECS) do
        data[spec.configVariable] = config[spec.configVariable]
    end
    return data
end

function widget:SetConfigData(data)
    if not data then return end
    if type(data.convUserPos) == "table" and tonumber(data.convUserPos[1]) and tonumber(data.convUserPos[2]) then
        convUserPos = { data.convUserPos[1], data.convUserPos[2] }
    end
    for _, spec in ipairs(OPTION_SPECS) do
        local v = data[spec.configVariable]
        if spec.type == "bool" then
            if type(v) == "boolean" then config[spec.configVariable] = v end
        elseif spec.type == "select" then
            for _, opt in ipairs(spec.options) do
                if v == opt then config[spec.configVariable] = v end
            end
        end
    end
end

function widget:GetTooltip(mx, my)
    if self:IsAbove(mx, my) then
        return CONV_TIP_TITLE .. "\n" .. ConvTooltipText()
    end
    return nil
end

function widget:Shutdown()
    UnregisterOptions()
    if WG['tooltip'] and WG['tooltip'].RemoveTooltip then
        WG['tooltip'].RemoveTooltip('energyconvmeter')
    end
    if WG.snapRects then WG.snapRects[SNAP_KEY] = nil end
end
