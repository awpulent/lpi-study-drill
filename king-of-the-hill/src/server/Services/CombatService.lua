-- CombatService: rifle Tool, server-authoritative hitscan, armor and damage/kill credit.
-- Public API (dot-call): GiveRifle, GiveArmor, DamageHumanoid, ResetAll, HasRifle, IsArmorFull.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local CombatService = {}

local KILL_CREDIT_WINDOW = 10
local VEST_NAME = "ArmorVest"

type AmmoState = {
	ammo: number,
	reloading: boolean,
	lastFire: number,
	nextShot: number,
}

local states: { [Player]: AmmoState } = {}
local lastAttacker: { [Humanoid]: { player: Player, time: number } } = setmetatable({}, { __mode = "k" }) :: any
local watched: { [Humanoid]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local playerConns: { [Player]: { RBXScriptConnection } } = {}

-- Lazy sibling access (avoids circular requires) ------------------------------------------------

local function Economy()
	return require(script.Parent.EconomyService)
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

-- Helpers ----------------------------------------------------------------------------------------

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function isFiniteVector(v: any): boolean
	return typeof(v) == "Vector3" and isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)
end

local function notify(player: Player?, text: string, kind: string)
	if player and player.Parent == Players then
		Remotes.event("Notify"):FireClient(player, text, kind)
	end
end

local function sendAmmo(player: Player)
	local st = states[player]
	if st then
		Remotes.event("AmmoUpdate"):FireClient(player, st.ammo, st.reloading)
	end
end

local function getHumanoid(character: Model?): Humanoid?
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function isAlive(player: Player): (boolean, Model?, Humanoid?)
	local character = player.Character
	local humanoid = getHumanoid(character)
	if character and humanoid and humanoid.Health > 0 then
		return true, character, humanoid
	end
	return false, character, humanoid
end

local function findRifle(player: Player): Tool?
	local character = player.Character
	if character then
		local t = character:FindFirstChild(Config.Rifle.ToolName)
		if t and t:IsA("Tool") then
			return t
		end
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		local t = backpack:FindFirstChild(Config.Rifle.ToolName)
		if t and t:IsA("Tool") then
			return t
		end
	end
	return nil
end

local function teamColor(player: Player): Color3
	local team = player.Team
	if team then
		return team.TeamColor.Color
	end
	return Color3.fromRGB(120, 120, 120)
end

-- Rifle construction ----------------------------------------------------------------------------

local function detailPart(name: string, size: Vector3, offset: Vector3, handle: BasePart, color: Color3, tool: Tool)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.Metal
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CFrame = handle.CFrame * CFrame.new(offset)
	p.Parent = tool
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = p
	weld.Parent = p
	return p
end

local function buildRifle(): Tool
	local tool = Instance.new("Tool")
	tool.Name = Config.Rifle.ToolName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Assault Rifle"
	-- Barrel points along the handle's -Z (front) axis; hold near the rear of the body.
	tool.GripPos = Vector3.new(0, -0.35, 0.9)
	tool.GripForward = Vector3.new(0, 0, -1)
	tool.GripUp = Vector3.new(0, 1, 0)
	tool.GripRight = Vector3.new(1, 0, 0)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 0.8, 4)
	handle.Color = Color3.fromRGB(45, 47, 52)
	handle.Material = Enum.Material.Metal
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.CFrame = CFrame.new()
	handle.Parent = tool

	local dark = Color3.fromRGB(28, 29, 32)
	local mid = Color3.fromRGB(70, 72, 78)
	detailPart("Magazine", Vector3.new(0.3, 1.3, 0.55), Vector3.new(0, -1.0, -0.1), handle, dark, tool)
	detailPart("Stock", Vector3.new(0.35, 0.7, 1.1), Vector3.new(0, -0.1, 2.5), handle, mid, tool)
	detailPart("Grip", Vector3.new(0.3, 0.8, 0.35), Vector3.new(0, -0.7, 0.9), handle, dark, tool)
	detailPart("Barrel", Vector3.new(0.18, 0.18, 1.3), Vector3.new(0, 0.1, -2.6), handle, mid, tool)
	detailPart("Sight", Vector3.new(0.15, 0.25, 0.4), Vector3.new(0, 0.5, -0.8), handle, dark, tool)

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0.1, -3.3)
	muzzle.Parent = handle

	return tool
end

-- Armor vest -------------------------------------------------------------------------------------

local function removeVest(character: Model?)
	if not character then
		return
	end
	local vest = character:FindFirstChild(VEST_NAME)
	if vest then
		vest:Destroy()
	end
end

local function addVest(player: Player, character: Model)
	removeVest(character)
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not torso or not torso:IsA("BasePart") then
		return
	end
	local vest = Instance.new("Part")
	vest.Name = VEST_NAME
	vest.Size = torso.Size + Vector3.new(0.25, 0.05, 0.25)
	vest.Color = teamColor(player)
	vest.Material = Enum.Material.SmoothPlastic
	vest.Transparency = 0.25
	vest.CanCollide = false
	vest.CanQuery = false
	vest.CanTouch = false
	vest.Massless = true
	vest.CFrame = torso.CFrame
	vest.Parent = character
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = torso
	weld.Part1 = vest
	weld.Parent = vest
end

local function setArmor(player: Player, value: number)
	player:SetAttribute("Armor", math.max(0, value))
	if value <= 0 then
		removeVest(player.Character)
	end
end

-- Damage / kills -------------------------------------------------------------------------------

local function sameTeam(a: Player?, b: Player?): boolean
	return a ~= nil and b ~= nil and a.Team ~= nil and a.Team == b.Team
end

local function onHumanoidDied(humanoid: Humanoid)
	local info = lastAttacker[humanoid]
	lastAttacker[humanoid] = nil
	if not info then
		return
	end
	local attacker = info.player
	if attacker.Parent ~= Players or os.clock() - info.time > KILL_CREDIT_WINDOW then
		return
	end
	local character = humanoid.Parent
	local victim = if character then Players:GetPlayerFromCharacter(character) else nil
	if victim == attacker or sameTeam(attacker, victim) then
		return
	end
	local victimName = if victim then victim.DisplayName elseif character then character.Name else "someone"
	pcall(function()
		Economy().AddCash(attacker, Config.Economy.KillPay, "Kill")
	end)
	notify(attacker, "You eliminated " .. victimName, "info")
	if victim then
		notify(victim, "Eliminated by " .. attacker.DisplayName, "info")
	end
end

local function watchHumanoid(humanoid: Humanoid)
	if watched[humanoid] then
		return
	end
	watched[humanoid] = true
	humanoid.Died:Once(function()
		onHumanoidDied(humanoid)
	end)
end

-- Returns true if the humanoid was killed by this damage.
function CombatService.DamageHumanoid(attacker: Player?, humanoid: Humanoid?, amount: number): boolean
	if not humanoid or humanoid.Parent == nil or humanoid.Health <= 0 then
		return false
	end
	if type(amount) ~= "number" or not isFinite(amount) or amount <= 0 then
		return false
	end
	local character = humanoid.Parent
	-- A ForceField blocks everything, including armor loss.
	if character and character:FindFirstChildOfClass("ForceField") then
		return false
	end
	watchHumanoid(humanoid)

	local victim = if character then Players:GetPlayerFromCharacter(character) else nil
	local remaining = amount
	if victim then
		local armor = victim:GetAttribute("Armor")
		if type(armor) == "number" and armor > 0 then
			local absorbed = math.min(armor, remaining)
			setArmor(victim, armor - absorbed)
			remaining -= absorbed
		end
	end
	if attacker and attacker ~= victim then
		lastAttacker[humanoid] = { player = attacker, time = os.clock() }
	end
	if remaining > 0 then
		humanoid:TakeDamage(remaining)
	end
	return humanoid.Health <= 0
end

-- Rifle ------------------------------------------------------------------------------------------

function CombatService.HasRifle(player: Player): boolean
	return findRifle(player) ~= nil
end

function CombatService.IsArmorFull(player: Player): boolean
	local armor = player:GetAttribute("Armor")
	local maxArmor = Config.Armor.Max
	return type(armor) == "number" and armor >= maxArmor
end

function CombatService.GiveRifle(player: Player): (boolean, string)
	local alive = isAlive(player)
	if not alive then
		return false, "You must be alive"
	end
	if findRifle(player) then
		return false, "You already have a rifle"
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "Backpack unavailable"
	end
	local tool = buildRifle()
	states[player] = { ammo = Config.Rifle.MagazineSize, reloading = false, lastFire = 0, nextShot = 0 }
	tool.Equipped:Connect(function()
		sendAmmo(player)
	end)
	tool.Parent = backpack
	sendAmmo(player)
	return true, "Assault Rifle equipped"
end

function CombatService.GiveArmor(player: Player): (boolean, string)
	local alive, character = isAlive(player)
	if not alive or not character then
		return false, "You must be alive"
	end
	if CombatService.IsArmorFull(player) then
		return false, "Armor already full"
	end
	player:SetAttribute("MaxArmor", Config.Armor.Max)
	setArmor(player, Config.Armor.Max)
	addVest(player, character)
	return true, "Armor equipped"
end

function CombatService.ResetAll()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local t = character:FindFirstChild(Config.Rifle.ToolName)
			if t then
				t:Destroy()
			end
		end
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then
			local t = backpack:FindFirstChild(Config.Rifle.ToolName)
			if t then
				t:Destroy()
			end
		end
		states[player] = nil
		setArmor(player, 0)
		Remotes.event("AmmoUpdate"):FireClient(player, 0, false)
	end
end

local function startReload(player: Player)
	local st = states[player]
	if not st or st.reloading or st.ammo >= Config.Rifle.MagazineSize then
		return
	end
	st.reloading = true
	sendAmmo(player)
	task.delay(Config.Rifle.ReloadTime, function()
		if states[player] ~= st then
			return -- rifle was replaced/removed meanwhile
		end
		st.ammo = Config.Rifle.MagazineSize
		st.reloading = false
		sendAmmo(player)
	end)
end

local function buildRayParams(player: Player, character: Model): RaycastParams
	local exclude: { Instance } = { character }
	local hot = Workspace:FindFirstChild("Hotzone")
	if hot then
		table.insert(exclude, hot)
	end
	local map = Workspace:FindFirstChild("Map")
	local cz = map and map:FindFirstChild("CombatZone")
	if cz then
		table.insert(exclude, cz)
	end
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if vehicles then
		for _, v in vehicles:GetChildren() do
			if v:GetAttribute("OwnerUserId") == player.UserId then
				table.insert(exclude, v)
			end
		end
		local hum = character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		if seat and seat:IsDescendantOf(vehicles) then
			local vm: Instance? = seat
			while vm and vm.Parent ~= vehicles do
				vm = vm.Parent
			end
			if vm and not table.find(exclude, vm) then
				table.insert(exclude, vm)
			end
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	return params
end

local function getVehicleModel(part: Instance): Model?
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if not vehicles or not part:IsDescendantOf(vehicles) then
		return nil
	end
	local svc = Vehicle()
	if svc and svc.GetVehicleFromPart then
		local ok, model = pcall(svc.GetVehicleFromPart, part)
		if ok and model then
			return model
		end
	end
	-- Fallback: the ancestor that is a direct child of Workspace.Vehicles
	local cur: Instance? = part
	while cur and cur.Parent ~= vehicles do
		cur = cur.Parent
	end
	if cur and cur:IsA("Model") then
		return cur
	end
	return nil
end

local function handleFire(player: Player, aimPoint: any)
	if not isFiniteVector(aimPoint) then
		return
	end
	local alive, character, humanoid = isAlive(player)
	if not alive or not character or not humanoid then
		return
	end
	local st = states[player]
	if not st then
		return
	end
	local tool = character:FindFirstChild(Config.Rifle.ToolName)
	if not tool or not tool:IsA("Tool") then
		return
	end
	if st.reloading then
		return
	end
	local now = os.clock()
	local interval = 1 / Config.Rifle.FireRate
	if now < (st.nextShot or 0) - interval * 0.5 then
		return
	end
	if st.ammo <= 0 then
		startReload(player)
		return
	end
	st.nextShot = math.max(st.nextShot or 0, now) + interval
	st.lastFire = now
	st.ammo -= 1
	sendAmmo(player)

	local params = buildRayParams(player, character)
	local head = character:FindFirstChild("Head")
	local handle = tool:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	local headPos: Vector3? = if head and head:IsA("BasePart") then head.Position else nil
	local origin: Vector3
	if muzzle and muzzle:IsA("Attachment") then
		origin = muzzle.WorldPosition
		if headPos then
			local delta = origin - headPos
			if delta.Magnitude > 0.01 and Workspace:Raycast(headPos, delta, params) then
				origin = headPos -- muzzle is behind a wall; shoot from the head instead
			end
		end
	elseif headPos then
		origin = headPos
	else
		return
	end

	local range = Config.Rifle.Range
	local dir = aimPoint - origin
	if dir.Magnitude < 1e-3 then
		if head and head:IsA("BasePart") then
			dir = head.CFrame.LookVector
		else
			return
		end
	end
	dir = dir.Unit
	local aim = CFrame.lookAt(origin, origin + dir)
	local spread = aim * CFrame.Angles(0, 0, math.random() * math.pi * 2) * CFrame.Angles(math.random() * Config.Rifle.Spread, 0, 0)
	local direction = spread.LookVector * range

	local result = Workspace:Raycast(origin, direction, params)
	local hitPos = if result then result.Position else origin + direction
	Remotes.event("WeaponFx"):FireAllClients(player, origin, hitPos)

	if not result then
		return
	end
	local hitPart = result.Instance
	local hitEvent = Remotes.event("HitMarker")

	-- Vehicle hit
	local vehicleModel = getVehicleModel(hitPart)
	if vehicleModel then
		local vTeam = vehicleModel:GetAttribute("Team")
		if player.Team and vTeam == player.Team.Name then
			return
		end
		local svc = Vehicle()
		if svc and svc.DamageVehicle then
			local ok = pcall(svc.DamageVehicle, vehicleModel, Config.Rifle.VehicleDamage, player)
			if ok then
				hitEvent:FireClient(player, false, false)
			end
		end
		return
	end

	-- Character hit
	local model = hitPart:FindFirstAncestorOfClass("Model")
	local targetHumanoid = getHumanoid(model)
	if not model or not targetHumanoid or targetHumanoid.Health <= 0 then
		return
	end
	local targetPlayer = Players:GetPlayerFromCharacter(model)
	if targetPlayer == player or sameTeam(player, targetPlayer) then
		return
	end
	if model:FindFirstChildOfClass("ForceField") then
		return
	end
	local isHead = hitPart.Name == "Head"
	local damage = Config.Rifle.Damage * (if isHead then Config.Rifle.HeadshotMultiplier else 1)
	local killed = CombatService.DamageHumanoid(player, targetHumanoid, damage)
	hitEvent:FireClient(player, isHead, killed)
end

-- Per-player setup -------------------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	states[player] = nil
	player:SetAttribute("MaxArmor", Config.Armor.Max)
	player:SetAttribute("Armor", 0)
	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			watchHumanoid(humanoid)
			humanoid.Died:Once(function()
				-- Armor and vest vanish on death (rifle is lost with the Backpack).
				if player.Parent == Players then
					setArmor(player, 0)
				end
			end)
		end
	end)
end

local function setupPlayer(player: Player)
	if playerConns[player] then
		return
	end
	player:SetAttribute("MaxArmor", Config.Armor.Max)
	player:SetAttribute("Armor", 0)
	local conns = {}
	playerConns[player] = conns
	table.insert(
		conns,
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
	)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

function CombatService.Init(_self)
	Remotes.event("FireWeapon").OnServerEvent:Connect(function(player, aimPoint)
		handleFire(player, aimPoint)
	end)
	Remotes.event("ReloadWeapon").OnServerEvent:Connect(function(player)
		local alive = isAlive(player)
		if alive then
			startReload(player)
		end
	end)
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(player)
		local conns = playerConns[player]
		if conns then
			for _, c in conns do
				c:Disconnect()
			end
			playerConns[player] = nil
		end
		states[player] = nil
	end)
	for _, p in Players:GetPlayers() do
		setupPlayer(p)
	end
end

return CombatService
