-- TeamService: creates Teams, balances players, and applies SpawnLocation team colors.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local Config = require(ReplicatedStorage.Shared.Config)

local TeamService = {}

local teamsByName: { [string]: Team } = {}
local teamConfigByName: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

local function findTeamByColor(color: BrickColor): string?
	for _, t in Config.Teams do
		if t.BrickColor == color then
			return t.Name
		end
	end
	return nil
end

local function applySpawn(spawn: SpawnLocation)
	local teamName = spawn:GetAttribute("Team")
	if type(teamName) ~= "string" or teamConfigByName[teamName] == nil then
		-- Fall back to the enclosing base model name (Map.Bases.<Team>)
		teamName = nil
		local p = spawn.Parent
		while p and p ~= workspace do
			if teamConfigByName[p.Name] and p.Parent and p.Parent.Name == "Bases" then
				teamName = p.Name
				break
			end
			p = p.Parent
		end
	end
	if teamName == nil then
		return
	end
	spawn.Neutral = false
	spawn.TeamColor = teamConfigByName[teamName].BrickColor
end

local function applyAllSpawns()
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return false
	end
	for _, d in bases:GetDescendants() do
		if d:IsA("SpawnLocation") then
			applySpawn(d)
		end
	end
	return true
end

local function teamCounts(exclude: Player?): { [string]: number }
	local counts = {}
	for _, t in Config.Teams do
		counts[t.Name] = 0
	end
	for _, p in Players:GetPlayers() do
		if p ~= exclude and p.Team then
			local n = p.Team.Name
			if counts[n] ~= nil then
				counts[n] += 1
			end
		end
	end
	return counts
end

local function assignPlayer(player: Player)
	player.Neutral = false
	local counts = teamCounts(player)
	local smallest = math.huge
	for _, c in counts do
		smallest = math.min(smallest, c)
	end
	local candidates = {}
	for _, t in Config.Teams do
		if counts[t.Name] == smallest then
			table.insert(candidates, t.Name)
		end
	end
	local pick = candidates[math.random(1, #candidates)]
	player.Team = teamsByName[pick]
end

function TeamService.GetTeamName(player: Player): string?
	local t = player.Team
	if t and teamConfigByName[t.Name] then
		return t.Name
	end
	return nil
end

function TeamService.GetBase(teamName: string): Model?
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	local base = bases and bases:FindFirstChild(teamName)
	if base and base:IsA("Model") then
		return base
	end
	return nil
end

function TeamService.RespawnAll()
	for _, p in Players:GetPlayers() do
		task.spawn(function()
			if p.Parent == Players then
				p:LoadCharacter()
			end
		end)
	end
end

function TeamService.Init(_self)
	for _, t in Config.Teams do
		local team = Teams:FindFirstChild(t.Name)
		if not (team and team:IsA("Team")) then
			team = Instance.new("Team")
			team.Name = t.Name
			team.Parent = Teams
		end
		team.TeamColor = t.BrickColor
		team.AutoAssignable = false
		teamsByName[t.Name] = team
		teamConfigByName[t.Name] = t
	end

	-- Spawns (the map may already exist in the place file)
	applyAllSpawns()

	table.insert(
		connections,
		Players.PlayerAdded:Connect(function(player)
			assignPlayer(player)
		end)
	)
	for _, p in Players:GetPlayers() do
		if not (p.Team and teamConfigByName[p.Team.Name]) then
			assignPlayer(p)
			if p.Character then
				task.defer(function()
					p:LoadCharacter()
				end)
			end
		end
	end
end

function TeamService.Start(_self)
	-- Map may be inserted after Init (or streamed in); apply again and keep new spawns colored.
	local map = workspace:WaitForChild("Map", 30)
	if not map then
		warn("[TeamService] Workspace.Map not found; spawns not team-colored")
		return
	end
	local bases = map:WaitForChild("Bases", 30)
	if not bases then
		return
	end
	applyAllSpawns()
	table.insert(
		connections,
		bases.DescendantAdded:Connect(function(d)
			if d:IsA("SpawnLocation") then
				applySpawn(d)
			end
		end)
	)
end

-- Exposed for other modules that need to translate colors.
function TeamService.GetTeamNameFromColor(color: BrickColor): string?
	return findTeamByColor(color)
end

return TeamService
