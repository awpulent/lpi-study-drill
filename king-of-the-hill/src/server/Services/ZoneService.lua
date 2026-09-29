-- ZoneService: gliding Hotzone + per-player Zone attribute ("None" | "Combat" | "Hot").

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local ZoneService = {}

local ZC = Config.Zones
local DISC_THICKNESS = 0.4
local DISC_Y = 0.6 -- above ground (and above the CombatZone visual disc)
local PILLAR_HEIGHT = 140
local FLAT = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis is X; rotate so it points up

local hotPart: Part? = nil
local pillarPart: Part? = nil
local hotPos = Vector3.new(ZC.Center.X, ZC.Center.Y, ZC.Center.Z) -- ground level center of hotzone
local target: Vector3? = nil
local pauseUntil = 0
local zones: { [Player]: string } = {}

local function placeVisuals()
	if hotPart then
		hotPart.CFrame = CFrame.new(hotPos.X, hotPos.Y + DISC_Y, hotPos.Z) * FLAT
	end
	if pillarPart then
		pillarPart.CFrame = CFrame.new(hotPos.X, hotPos.Y + PILLAR_HEIGHT / 2, hotPos.Z) * FLAT
	end
end

local function randomWaypoint(): Vector3
	local maxR = math.max(0, ZC.CombatRadius - ZC.HotzoneRadius)
	local angle = math.random() * math.pi * 2
	local r = math.sqrt(math.random()) * maxR
	return Vector3.new(ZC.Center.X + math.cos(angle) * r, ZC.Center.Y, ZC.Center.Z + math.sin(angle) * r)
end

local function horizontalDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function evaluate(player: Player): string
	local char = player.Character
	if not char then
		return "None"
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not root or not root:IsA("BasePart") then
		return "None"
	end
	local pos = root.Position
	local height = pos.Y - ZC.Center.Y
	if height < -6 or height > ZC.CombatHeight then
		return "None"
	end
	if horizontalDistance(pos, ZC.Center) > ZC.CombatRadius then
		return "None"
	end
	if horizontalDistance(pos, hotPos) <= ZC.HotzoneRadius then
		return "Hot"
	end
	return "Combat"
end

local function createVisuals()
	local old = Workspace:FindFirstChild("Hotzone")
	if old then
		old:Destroy()
	end
	local oldPillar = Workspace:FindFirstChild("HotzonePillar")
	if oldPillar then
		oldPillar:Destroy()
	end

	local disc = Instance.new("Part")
	disc.Name = "Hotzone"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(DISC_THICKNESS, ZC.HotzoneRadius * 2, ZC.HotzoneRadius * 2)
	disc.Material = Enum.Material.Neon
	disc.Color = Color3.fromRGB(255, 140, 20)
	disc.Transparency = 0.5
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	disc.TopSurface = Enum.SurfaceType.Smooth
	disc.BottomSurface = Enum.SurfaceType.Smooth

	local pillar = Instance.new("Part")
	pillar.Name = "HotzonePillar"
	pillar.Shape = Enum.PartType.Cylinder
	pillar.Size = Vector3.new(PILLAR_HEIGHT, 4, 4)
	pillar.Material = Enum.Material.Neon
	pillar.Color = Color3.fromRGB(255, 160, 40)
	pillar.Transparency = 0.85
	pillar.Anchored = true
	pillar.CanCollide = false
	pillar.CanQuery = false
	pillar.CanTouch = false
	pillar.CastShadow = false

	local gui = Instance.new("BillboardGui")
	gui.Name = "HotzoneLabel"
	gui.Size = UDim2.fromOffset(200, 50)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 30, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 2000
	gui.Adornee = disc
	gui.Parent = disc
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "HOTZONE \u{00D7}2"
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 170, 50)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui

	hotPart = disc
	pillarPart = pillar
	placeVisuals()
	pillar.Parent = Workspace
	disc.Parent = Workspace
end

function ZoneService.GetPlayerZone(player: Player): string
	return zones[player] or "None"
end

function ZoneService.ResetHotzone()
	hotPos = Vector3.new(ZC.Center.X, ZC.Center.Y, ZC.Center.Z)
	target = nil
	pauseUntil = os.clock() + ZC.HotzonePause
	placeVisuals()
end

function ZoneService.Init(_self)
	createVisuals()
	pauseUntil = os.clock() + ZC.HotzonePause
	Players.PlayerRemoving:Connect(function(p)
		zones[p] = nil
	end)
end

function ZoneService.Start(_self)
	-- Glide the hotzone
	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		if now < pauseUntil then
			return
		end
		if not target then
			target = randomWaypoint()
		end
		local delta = (target :: Vector3) - hotPos
		local dist = delta.Magnitude
		local step = ZC.HotzoneSpeed * dt
		if dist <= step then
			hotPos = target :: Vector3
			target = nil
			pauseUntil = now + ZC.HotzonePause
		else
			hotPos += delta.Unit * step
		end
		placeVisuals()
	end)

	-- Zone attributes every 0.2s (absolute scheduling)
	local nextAt = os.clock()
	while true do
		for _, p in Players:GetPlayers() do
			local z = evaluate(p)
			zones[p] = z
			if p:GetAttribute("Zone") ~= z then
				p:SetAttribute("Zone", z)
			end
		end
		nextAt += 0.2
		local wait = nextAt - os.clock()
		if wait < 0 then
			nextAt = os.clock()
			wait = 0
		end
		task.wait(wait)
	end
end

return ZoneService
