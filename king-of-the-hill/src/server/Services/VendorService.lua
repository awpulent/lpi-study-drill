-- VendorService: ProximityPrompts on base vendors and the server-side Purchase handler.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local VendorService = {}

local PURCHASE_DEBOUNCE = 0.5

type Vendor = {
	model: Model,
	vendorType: string,
	team: string?,
	part: BasePart,
}

local vendors: { Vendor } = {}
local lastPurchase: { [Player]: number } = {}
local busy: { [Player]: boolean } = {}

local function Economy()
	return require(script.Parent.EconomyService)
end

local function Combat()
	return require(script.Parent.CombatService)
end

local function Vehicle()
	local ok, svc = pcall(function()
		return require(script.Parent.VehicleService)
	end)
	if ok then
		return svc
	end
	return nil
end

local function getTeamName(player: Player): string?
	local ok, name = pcall(function()
		return require(script.Parent.TeamService).GetTeamName(player)
	end)
	if ok and type(name) == "string" then
		return name
	end
	if player.Team then
		return player.Team.Name
	end
	return nil
end

local function notify(player: Player, text: string, kind: string)
	Remotes.event("Notify"):FireClient(player, text, kind)
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Refunds -----------------------------------------------------------------------------------------
-- EconomyService has no Refund() (AddCash would apply the hotzone multiplier and a notification), so
-- unless one appears we restore the cash directly on the Cash attribute and leaderstats mirror.
local function refund(player: Player, amount: number)
	local ok, done = pcall(function()
		local eco = Economy()
		if type(eco.Refund) == "function" then
			eco.Refund(player, amount)
			return true
		end
		return false
	end)
	if ok and done then
		return
	end
	local current = player:GetAttribute("Cash")
	if type(current) ~= "number" then
		current = 0
	end
	local newCash = current + amount
	player:SetAttribute("Cash", newCash)
	local stats = player:FindFirstChild("leaderstats")
	local cashValue = stats and stats:FindFirstChild("Cash")
	if cashValue and (cashValue:IsA("IntValue") or cashValue:IsA("NumberValue")) then
		cashValue.Value = math.floor(newCash + 0.5)
	end
end

-- Purchase ----------------------------------------------------------------------------------------

local function nearOwnVendor(player: Player, vendorType: string): boolean
	local root = getRoot(player)
	local team = getTeamName(player)
	if not root or not team then
		return false
	end
	local maxDist = Config.VendorInteractDistance + 4
	for _, v in vendors do
		if v.vendorType == vendorType and v.team == team and v.part.Parent then
			if (v.part.Position - root.Position).Magnitude <= maxDist then
				return true
			end
		end
	end
	return false
end

local function deliver(player: Player, itemId: string): (boolean, string)
	if itemId == "AssaultRifle" then
		return Combat().GiveRifle(player)
	elseif itemId == "Armor" then
		return Combat().GiveArmor(player)
	elseif itemId == "Car" or itemId == "Helicopter" then
		local svc = Vehicle()
		if not svc or type(svc.SpawnVehicle) ~= "function" then
			return false, "Vehicles are unavailable"
		end
		local ok, success, msg = pcall(svc.SpawnVehicle, player, itemId)
		if not ok then
			return false, "Vehicle spawn failed"
		end
		return success == true, if type(msg) == "string" then msg else ""
	end
	return false, "Unknown item"
end

local function purchase(player: Player, itemId: any): (boolean, string)
	if type(itemId) ~= "string" then
		return false, "Invalid item"
	end
	local item = Config.Shop[itemId]
	if not item then
		return false, "Invalid item"
	end
	local now = os.clock()
	if busy[player] or now - (lastPurchase[player] or 0) < PURCHASE_DEBOUNCE then
		return false, "Please wait"
	end
	lastPurchase[player] = now

	local gs = ReplicatedStorage:FindFirstChild("GameState")
	if not gs or gs:GetAttribute("Phase") ~= "Playing" then
		return false, "Shop is closed right now"
	end
	if not getRoot(player) then
		return false, "You must be alive"
	end
	if not nearOwnVendor(player, item.Vendor) then
		return false, "Move closer to your base's vendor"
	end

	-- Feasibility pre-checks before spending
	local combatOk, combat = pcall(Combat)
	if itemId == "AssaultRifle" and combatOk and combat.HasRifle(player) then
		return false, "You already have a rifle"
	end
	if itemId == "Armor" and combatOk and combat.IsArmorFull(player) then
		return false, "Armor already full"
	end

	local price = item.Price
	local cash = Economy().GetCash(player)
	if cash < price then
		return false, string.format("Not enough cash ($%d / $%d)", math.floor(cash), price)
	end

	busy[player] = true
	local spent = Economy().TrySpend(player, price)
	if not spent then
		busy[player] = nil
		return false, string.format("Not enough cash ($%d / $%d)", math.floor(Economy().GetCash(player)), price)
	end
	local ok, success, msg = pcall(deliver, player, itemId)
	busy[player] = nil
	if not ok or not success then
		if player.Parent == Players then
			refund(player, price)
		end
		local reason = if ok and type(msg) == "string" and msg ~= "" then msg else "Delivery failed"
		return false, reason .. " (refunded)"
	end
	return true, "Purchased " .. item.Name
end

-- Vendors -----------------------------------------------------------------------------------------

local function setupVendor(model: Model)
	local vendorType = model:GetAttribute("VendorType")
	if type(vendorType) ~= "string" then
		return
	end
	local part: Instance? = model.PrimaryPart or model:FindFirstChild("Counter")
	if not part or not part:IsA("BasePart") then
		return
	end
	if part:FindFirstChild("VendorPrompt") then
		return
	end
	local teamAttr = model:GetAttribute("Team")
	local team = if type(teamAttr) == "string" then teamAttr else nil
	table.insert(vendors, { model = model, vendorType = vendorType, team = team, part = part })

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "VendorPrompt"
	prompt.ActionText = "Shop"
	prompt.ObjectText = if vendorType == "Vehicle" then "Vehicle Vendor" else "Gear Vendor"
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = Config.VendorInteractDistance
	prompt.Parent = part
	prompt.Triggered:Connect(function(player)
		if getTeamName(player) ~= team then
			notify(player, "This isn't your base's vendor", "error")
			return
		end
		Remotes.event("OpenShop"):FireClient(player, vendorType)
	end)
end

function VendorService.Init(_self)
	Remotes.func("Purchase").OnServerInvoke = function(player, itemId)
		local ok, success, msg = pcall(purchase, player, itemId)
		if not ok then
			busy[player] = nil
			return false, "Purchase failed"
		end
		return success, msg
	end
	Players.PlayerRemoving:Connect(function(player)
		lastPurchase[player] = nil
		busy[player] = nil
	end)
end

function VendorService.Start(_self)
	local map = Workspace:WaitForChild("Map", 60)
	if not map then
		warn("[VendorService] Workspace.Map not found")
		return
	end
	local bases = map:WaitForChild("Bases", 30)
	if not bases then
		warn("[VendorService] Map.Bases not found")
		return
	end
	for _, d in bases:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute("VendorType") ~= nil then
			setupVendor(d)
		end
	end
end

return VendorService
