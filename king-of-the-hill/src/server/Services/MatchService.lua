-- MatchService: owns ReplicatedStorage.GameState and the score tick / intermission loop.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local MatchService = {}

local M = Config.Match
local state: Folder

local function sibling(name: string): any?
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild(name, 5))
	end)
	if ok then
		return mod
	end
	warn(("[MatchService] could not load %s: %s"):format(name, tostring(mod)))
	return nil
end

-- Calls Service[fn](...) protected; a failure never propagates.
local function safeCall(serviceName: string, fn: string, ...)
	local args = table.pack(...)
	local ok, err = pcall(function()
		local svc = sibling(serviceName)
		if svc and svc[fn] then
			svc[fn](table.unpack(args, 1, args.n))
		end
	end)
	if not ok then
		warn(("[MatchService] %s.%s failed: %s"):format(serviceName, fn, tostring(err)))
	end
end

local function scoreOf(teamName: string): number
	local v = state:GetAttribute("Score_" .. teamName)
	return if type(v) == "number" then v else 0
end

local function scoreLine(): string
	local parts = {}
	for _, t in Config.Teams do
		table.insert(parts, ("%s %d"):format(t.Name, scoreOf(t.Name)))
	end
	return table.concat(parts, " / ")
end

local function notifyAll(text: string)
	Remotes.event("Notify"):FireAllClients(text, "score")
end

local function resetScores()
	for _, t in Config.Teams do
		state:SetAttribute("Score_" .. t.Name, 0)
	end
	state:SetAttribute("Winner", "")
	state:SetAttribute("LastTickWinner", "")
end

local function endMatch(winner: string)
	state:SetAttribute("Winner", winner)
	state:SetAttribute("Phase", "Intermission")
	state:SetAttribute("IntermissionEndsAt", workspace:GetServerTimeNow() + M.IntermissionTime)
	notifyAll(string.upper(winner) .. " WINS THE MATCH!")
	safeCall("CombatService", "ResetAll")
	safeCall("VehicleService", "DespawnAll")
	safeCall("ZoneService", "ResetHotzone")
end

local function startNextMatch()
	resetScores()
	state:SetAttribute("NextTickAt", workspace:GetServerTimeNow() + M.TickInterval)
	state:SetAttribute("IntermissionEndsAt", 0)
	state:SetAttribute("Phase", "Playing")
	safeCall("TeamService", "RespawnAll")
end

local function doTick()
	local Zone = sibling("ZoneService")
	local Team = sibling("TeamService")
	local Economy = sibling("EconomyService")
	if not (Zone and Team and Economy) then
		state:SetAttribute("LastTickWinner", "")
		return
	end

	local weights = {}
	for _, t in Config.Teams do
		weights[t.Name] = 0
	end

	for _, p in Players:GetPlayers() do
		local zone = Zone.GetPlayerZone(p)
		if zone == "Combat" or zone == "Hot" then
			local teamName = Team.GetTeamName(p)
			if teamName and weights[teamName] ~= nil then
				weights[teamName] += if zone == "Hot" then M.HotzoneWeight else 1
			end
			pcall(Economy.AddCash, p, Config.Economy.ZoneTickPay, "Zone tick")
		end
	end

	local best, bestName, tie = 0, "", false
	for _, t in Config.Teams do
		local w = weights[t.Name]
		if w > best then
			best, bestName, tie = w, t.Name, false
		elseif w == best and w > 0 then
			tie = true
		end
	end

	if best <= 0 then
		state:SetAttribute("LastTickWinner", "")
		notifyAll("No team holds the zone")
	elseif tie then
		state:SetAttribute("LastTickWinner", "")
		notifyAll("Tie \u{2014} no point")
	else
		local newScore = scoreOf(bestName) + 1
		state:SetAttribute("Score_" .. bestName, newScore)
		state:SetAttribute("LastTickWinner", bestName)
		notifyAll(("%s scores! (%s)"):format(bestName, scoreLine()))
		if newScore >= M.PointsToWin then
			endMatch(bestName)
		end
	end
end

function MatchService.GetPhase(): string
	local v = state and state:GetAttribute("Phase")
	return if type(v) == "string" then v else "Playing"
end

function MatchService.Init(_self)
	local existing = ReplicatedStorage:FindFirstChild("GameState")
	if existing then
		existing:Destroy()
	end
	state = Instance.new("Folder")
	state.Name = "GameState"
	state:SetAttribute("Phase", "Playing")
	for _, t in Config.Teams do
		state:SetAttribute("Score_" .. t.Name, 0)
	end
	state:SetAttribute("NextTickAt", workspace:GetServerTimeNow() + M.TickInterval)
	state:SetAttribute("IntermissionEndsAt", 0)
	state:SetAttribute("Winner", "")
	state:SetAttribute("LastTickWinner", "")
	state.Parent = ReplicatedStorage
end

function MatchService.Start(_self)
	local idle = false
	local nextTick = workspace:GetServerTimeNow() + M.TickInterval

	while true do
		local now = workspace:GetServerTimeNow()
		local phase = state:GetAttribute("Phase")

		if phase == "Intermission" then
			local ends = state:GetAttribute("IntermissionEndsAt")
			if type(ends) ~= "number" or now >= ends then
				startNextMatch()
				nextTick = state:GetAttribute("NextTickAt") :: number
				idle = false
			end
		else
			if #Players:GetPlayers() == 0 then
				-- Nobody here: freeze the countdown at a full interval.
				if not idle then
					idle = true
					state:SetAttribute("NextTickAt", now + M.TickInterval)
				end
			else
				if idle then
					idle = false
					nextTick = now + M.TickInterval
					state:SetAttribute("NextTickAt", nextTick)
				end
				if now >= nextTick then
					local ok, err = pcall(doTick)
					if not ok then
						warn("[MatchService] tick failed: " .. tostring(err))
					end
					if state:GetAttribute("Phase") == "Playing" then
						nextTick += M.TickInterval -- absolute schedule, no drift
						if nextTick <= now then
							nextTick = now + M.TickInterval
						end
						state:SetAttribute("NextTickAt", nextTick)
					end
				end
			end
		end
		task.wait(0.1)
	end
end

return MatchService
