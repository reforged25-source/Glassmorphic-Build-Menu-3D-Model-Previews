---@diagnostic disable: undefined-global
local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Top Bar Extra",
		desc = "Adds a more detailed resource display with continuous zero-allocation EMA telemetry.",
		author = "uBdead (refactored for AAA performance)",
		date = "2026.09",
		license = "GNU GPL, v2 or later",
		layer = -9999991,
		enabled = true,
	}
end

-- Spring API
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamResources = Spring.GetTeamResources
local spGetViewGeometry = Spring.GetViewGeometry
local spGetConfigFloat = Spring.GetConfigFloat
local isSingle = true

-- UI
local font

-- State (Single Float Registers - Zero GC Allocation)
local smoothed_metal_balance = 0.0
local smoothed_energy_balance = 0.0
local smoothed_metal_overflow_balance = 0.0
local smoothed_energy_overflow_balance = 0.0
local share_metal = 0.0
local share_energy = 0.0
local telemetryInitialized = false

-- Math & Formatting
local sformat = string.format
local math_floor = math.floor
local math_abs = math.abs

local function short(n, f)
	f = f or 0
	local abs_n = math_abs(n)

	if abs_n > 999999 then
		return sformat("%+." .. f .. "fm", n / 1000000)
	elseif abs_n > 999 then
		return sformat("%+." .. f .. "fk", n / 1000)
	else
		return sformat("%+d", n)
	end
end

function widget:Initialize()
	if WG.fonts then
		font = WG.fonts.getFont(2)
	end

	smoothed_metal_balance = 0.0
	smoothed_energy_balance = 0.0
	smoothed_metal_overflow_balance = 0.0
	smoothed_energy_overflow_balance = 0.0
	telemetryInitialized = false

	local myAllyTeamID = Spring.GetMyAllyTeamID()
	local teamList = Spring.GetTeamList(myAllyTeamID) or {}
	isSingle = #teamList == 1
end

function widget:ViewResize()
	if WG.fonts then
		font = WG.fonts.getFont(2)
	end
end

-- Telemetry engine: Sampled in GameFrame (simulation-rate deterministic, frame-rate independent)
function widget:GameFrame(n)
	-- Sample every 2 game frames (~15Hz telemetry update)
	if n % 2 ~= 0 then return end

	local myTeamID = spGetMyTeamID()
	if not myTeamID then return end

	-- Metal Telemetry
	local m, m_storage, m_pull, m_income, m_expense, m_share, m_sent, m_received = spGetTeamResources(myTeamID, 'metal')
	if m_income then
		share_metal = m_share or 0.0
		local m_balance = m_income - m_pull
		local m_overflow_balance = (m_received or 0) - (m_sent or 0)

		if not telemetryInitialized then
			smoothed_metal_balance = m_balance
			smoothed_metal_overflow_balance = m_overflow_balance
		else
			-- Exponential Moving Average: alpha = 0.09 (~1s time constant at 15Hz)
			smoothed_metal_balance = smoothed_metal_balance + 0.09 * (m_balance - smoothed_metal_balance)
			smoothed_metal_overflow_balance = smoothed_metal_overflow_balance + 0.09 * (m_overflow_balance - smoothed_metal_overflow_balance)
		end
	end

	-- Energy Telemetry
	local e, e_storage, e_pull, e_income, e_expense, e_share, e_sent, e_received = spGetTeamResources(myTeamID, 'energy')
	if e_income then
		share_energy = e_share or 0.0
		local e_balance = e_income - e_pull
		local e_overflow_balance = (e_received or 0) - (e_sent or 0)

		if not telemetryInitialized then
			smoothed_energy_balance = e_balance
			smoothed_energy_overflow_balance = e_overflow_balance
			telemetryInitialized = true
		else
			smoothed_energy_balance = smoothed_energy_balance + 0.09 * (e_balance - smoothed_energy_balance)
			smoothed_energy_overflow_balance = smoothed_energy_overflow_balance + 0.09 * (e_overflow_balance - smoothed_energy_overflow_balance)
		end
	end
end

-- Share slider layout helper
local function getShareSliderX(barLeft, barRight, value)
	local barWidth = barRight - barLeft
	local leftMargin = barWidth * 0.25
	local rightMargin = barWidth * 0.03
	return barLeft + leftMargin + value * (barWidth - leftMargin - rightMargin)
end

function widget:DrawScreen()
	if not font then
		if WG.fonts then
			font = WG.fonts.getFont(2)
		end
		if not font or not font.Begin then return end
	end

	local vsx, vsy = spGetViewGeometry()
	local ui_scale = tonumber(spGetConfigFloat("ui_scale", 1) or 1)
	local orgHeight = 46
	local height = orgHeight * (1 + (ui_scale - 1) / 1.7)
	local widgetScale = (0.80 + (vsx * vsy / 6000000))
	local relXpos = 0.3
	local borderPadding = 5
	local xPos = math_floor(vsx * relXpos)
	local widgetSpaceMargin = 5

	local topbarAreaLeft = math_floor(xPos + (borderPadding * widgetScale))
	local topbarAreaTop = math_floor(vsy - (height * widgetScale))
	local totalWidth = vsx - topbarAreaLeft
	local metal_width = math_floor(totalWidth / 4.4)
	local energy_width = metal_width

	local metalAreaLeft = topbarAreaLeft
	local metalAreaRight = topbarAreaLeft + metal_width
	local metalAreaBottom = topbarAreaTop
	local metalAreaTop = vsy

	local energyAreaLeft = topbarAreaLeft + metal_width + widgetSpaceMargin
	local energyAreaRight = energyAreaLeft + energy_width
	local energyAreaBottom = topbarAreaTop
	local energyAreaTop = vsy

	-- Zero-allocation direct font drawing pass
	font:Begin()
	font:SetOutlineColor(0, 0, 0, 1)

	-- Energy Balance Readout
	local e_balance = smoothed_energy_balance
	local e_color = e_balance >= 0 and "\255\120\235\120" or "\255\240\125\125"
	local e_barHeight = energyAreaTop - energyAreaBottom
	local e_x = energyAreaLeft + e_barHeight * 0.5
	local e_y = energyAreaBottom + e_barHeight * 0.5
	font:Print(e_color .. short(e_balance, 1), e_x, e_y, 24, "co")

	-- Metal Balance Readout
	local m_balance = smoothed_metal_balance
	local m_color = m_balance >= 0 and "\255\120\235\120" or "\255\240\125\125"
	local m_barHeight = metalAreaTop - metalAreaBottom
	local m_x = metalAreaLeft + m_barHeight * 0.5
	local m_y = metalAreaBottom + m_barHeight * 0.5
	font:Print(m_color .. short(m_balance, 1), m_x, m_y, 24, "co")

	-- Multi-player Overflow and Share Sliders
	if not isSingle then
		local e_overflow = smoothed_energy_overflow_balance
		local e_overflow_color = "\255\255\230\80"
		local e_slider_x = getShareSliderX(energyAreaLeft, energyAreaRight, share_energy)
		local e_overflow_y = e_y - e_barHeight * 0.10
		font:Print(e_overflow_color .. short(e_overflow, 1), e_slider_x, e_overflow_y, 18, "co")

		local m_overflow = smoothed_metal_overflow_balance
		local m_overflow_color = "\255\120\180\255"
		local m_slider_x = getShareSliderX(metalAreaLeft, metalAreaRight, share_metal)
		local m_overflow_y = m_y - m_barHeight * 0.10
		font:Print(m_overflow_color .. short(m_overflow, 1), m_slider_x, m_overflow_y, 18, "co")
	end

	font:End()
end
