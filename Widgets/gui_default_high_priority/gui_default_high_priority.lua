local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "High Priority 2.0",
		desc = "Automatically defaults new Construction Turrets (Nano Turrets), Factories, and Builders to High Priority without overriding player choices. (v2.0 by reforged25-source)",
		author = "reforged25-source / Codex",
		version = "2.0",
		date = "2026 (v2.0)",
		license = "GNU GPL, v2 or later",
		layer = 50,
		enabled = true,
		handler = true,
	}
end

local spGetMyTeamID = Spring.GetMyTeamID
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spValidUnitID = Spring.ValidUnitID

local myTeamID = spGetMyTeamID()

-- Fast Cache: maps unitDefID -> priorityCmdID (or false if unitDef has no priority toggle)
local priorityCmdCache = {}

-- Fast check whether a unit definition is a builder, factory, or nano turret
local function isConstructionUnitDef(unitDefID)
	if not unitDefID then return false end
	local ud = UnitDefs[unitDefID]
	if not ud then return false end
	return (ud.isBuilder or ud.isFactory or (ud.buildSpeed and ud.buildSpeed > 0))
end

-- Resolve Priority Command info once per UnitDefID
local function getPriorityCmd(unitID, unitDefID)
	if priorityCmdCache[unitDefID] ~= nil then
		return priorityCmdCache[unitDefID]
	end

	local cmdDescs = spGetUnitCmdDescs(unitID)
	if not cmdDescs then
		return nil
	end

	for i = 1, #cmdDescs do
		local desc = cmdDescs[i]
		if type(desc) == "table" then
			local name = (desc.name or ""):lower()
			local action = (desc.action or ""):lower()
			local tooltip = (desc.tooltip or ""):lower()

			if name:find("priority") or action:find("priority") or tooltip:find("priority") then
				local targetState = 1 -- High Priority is typically index 1 (state 1)
				if desc.params and #desc.params >= 2 then
					for p = 2, #desc.params do
						local text = tostring(desc.params[p] or ""):lower()
						if text:find("high") then
							targetState = p - 2
							break
						end
					end
				end

				local info = {
					cmdID = desc.id,
					targetState = targetState,
				}
				priorityCmdCache[unitDefID] = info
				return info
			end
		end
	end

	priorityCmdCache[unitDefID] = false
	return nil
end

-- Apply High Priority once to a newly completed builder or factory
local function applyHighPriorityOnce(unitID, unitDefID)
	if not spValidUnitID(unitID) then return end
	if spGetUnitTeam(unitID) ~= myTeamID then return end

	unitDefID = unitDefID or spGetUnitDefID(unitID)
	if not isConstructionUnitDef(unitDefID) then return end

	local pInfo = getPriorityCmd(unitID, unitDefID)
	if not pInfo then return end

	-- Issue order to set High Priority
	spGiveOrderToUnit(unitID, pInfo.cmdID, { pInfo.targetState }, {})
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
	if unitTeam == myTeamID then
		applyHighPriorityOnce(unitID, unitDefID)
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if unitTeam == myTeamID then
		applyHighPriorityOnce(unitID, unitDefID)
	end
end

function widget:UnitGiven(unitID, unitDefID, unitTeam, oldTeam)
	if unitTeam == myTeamID then
		applyHighPriorityOnce(unitID, unitDefID)
	end
end

function widget:PlayerChanged(playerID)
	myTeamID = spGetMyTeamID()
end

function widget:Initialize()
	myTeamID = spGetMyTeamID()
	priorityCmdCache = {}

	-- Check existing team units on startup (filtered strictly to construction units)
	local myUnits = Spring.GetTeamUnits(myTeamID)
	if myUnits then
		for i = 1, #myUnits do
			local uid = myUnits[i]
			local defID = spGetUnitDefID(uid)
			if isConstructionUnitDef(defID) then
				applyHighPriorityOnce(uid, defID)
			end
		end
	end
end
