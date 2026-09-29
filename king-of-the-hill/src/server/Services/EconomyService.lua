-- EconomyService: cash attribute + leaderstats mirror, payouts with hotzone bonus.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local EconomyService = {}

local playerConns: { [Player]: { RBXScriptConnection } } = {}

local function setupPlayer(player: Player)
	if playerConns[player] then
		return
	end
	local conns = {}
	playerConns[player] = conns

	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		stats.Parent = player
	end
	local cashValue = stats:FindFirstChild("Cash")
	if not cashValue then
		cashValue = Instance.new("IntValue")
		cashValue.Name = "Cash"
		cashValue.Parent = stats
	end

	if type(player:GetAttribute("Cash")) ~= "number" then
		player:SetAttribute("Cash", Config.Economy.StartingCash)
	end
	cashValue.Value = player:GetAttribute("Cash")

	table.insert(
		conns,
		player:GetAttributeChangedSignal("Cash"):Connect(function()
			local v = player:GetAttribute("Cash")
			if type(v) == "number" then
				cashValue.Value = math.floor(v + 0.5)
			end
		end)
	)
end

function EconomyService.GetCash(player: Player): number
	local v = player:GetAttribute("Cash")
	if type(v) == "number" then
		return v
	end
	return 0
end

function EconomyService.AddCash(player: Player, amount: number, reason: string): number
	if player.Parent ~= Players or amount ~= amount then
		return 0
	end
	local paid = amount
	local bonus = false
	if amount > 0 then
		local ok, zone = pcall(function()
			local ZoneService = require(script.Parent.ZoneService)
			return ZoneService.GetPlayerZone(player)
		end)
		if ok and zone == "Hot" then
			paid = amount * Config.Economy.HotzoneMultiplier
			bonus = true
		end
	end
	paid = math.floor(paid + 0.5)
	if paid == 0 then
		return 0
	end
	player:SetAttribute("Cash", math.max(0, EconomyService.GetCash(player) + paid))

	if paid > 0 then
		local text = string.format("+$%d %s", paid, reason)
		if bonus then
			text ..= " (Hotzone bonus!)"
		end
		Remotes.event("Notify"):FireClient(player, text, "cash")
	end
	return paid
end

function EconomyService.TrySpend(player: Player, amount: number): boolean
	if type(amount) ~= "number" or amount < 0 or amount ~= amount then
		return false
	end
	local cash = EconomyService.GetCash(player)
	if cash < amount then
		return false
	end
	player:SetAttribute("Cash", cash - amount)
	return true
end

function EconomyService.Init(_self)
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(player)
		local conns = playerConns[player]
		if conns then
			for _, c in conns do
				c:Disconnect()
			end
			playerConns[player] = nil
		end
	end)
	for _, p in Players:GetPlayers() do
		setupPlayer(p)
	end
end

return EconomyService
