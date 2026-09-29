-- WeaponController: drives the rifle Tool on the client (input, aiming, crosshair, hitmarker, tracers).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local WeaponController = {}

local player = Players.LocalPlayer

local FAR_DISTANCE = Config.Rifle.Range
local FIRE_INTERVAL = 1 / Config.Rifle.FireRate

-- State
local rifle: Tool? = nil
local ammo = Config.Rifle.MagazineSize
local reloading = false
local mouseHeld = false
local touchHeld = false
local padHeld = false
local touchInput: InputObject? = nil
local lastFire = 0
local lastReloadRequest = 0
local centerAim = false

local charConns: { RBXScriptConnection } = {}
local renderConn: RBXScriptConnection? = nil

-- GUI refs
local gui: ScreenGui
local crosshair: Frame
local hitmarker: Frame
local statusLabel: TextLabel
local fireButton: TextButton
local reloadButton: TextButton

local fireRemote: RemoteEvent
local reloadRemote: RemoteEvent

-- GUI ------------------------------------------------------------------------------------------

local function makeBar(parent: Instance, size: UDim2, pos: UDim2, color: Color3): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.Size = size
	f.Position = pos
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Parent = parent
	return f
end

local function styleButton(b: TextButton, text: string, pos: UDim2, size: UDim2)
	b.Text = text
	b.Size = size
	b.Position = pos
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
	b.BackgroundTransparency = 0.35
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 18
	b.AutoButtonColor = true
	b.Visible = false
	b.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.4
	stroke.Thickness = 2
	stroke.Parent = b
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "WeaponGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.Parent = player:WaitForChild("PlayerGui")

	crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.BackgroundTransparency = 1
	crosshair.Size = UDim2.fromOffset(44, 44)
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Visible = false
	crosshair.Parent = gui

	local white = Color3.new(1, 1, 1)
	makeBar(crosshair, UDim2.fromOffset(2, 2), UDim2.fromScale(0.5, 0.5), white)
	makeBar(crosshair, UDim2.fromOffset(2, 9), UDim2.new(0.5, 0, 0, 5), white)
	makeBar(crosshair, UDim2.fromOffset(2, 9), UDim2.new(0.5, 0, 1, -5), white)
	makeBar(crosshair, UDim2.fromOffset(9, 2), UDim2.new(0, 5, 0.5, 0), white)
	makeBar(crosshair, UDim2.fromOffset(9, 2), UDim2.new(1, -5, 0.5, 0), white)

	hitmarker = Instance.new("Frame")
	hitmarker.Name = "Hitmarker"
	hitmarker.BackgroundTransparency = 1
	hitmarker.Size = UDim2.fromOffset(30, 30)
	hitmarker.AnchorPoint = Vector2.new(0.5, 0.5)
	hitmarker.Position = UDim2.fromScale(0.5, 0.5)
	hitmarker.Visible = false
	hitmarker.Parent = crosshair
	for _, rot in { 45, -45 } do
		local bar = makeBar(hitmarker, UDim2.fromOffset(4, 30), UDim2.fromScale(0.5, 0.5), white)
		bar.Name = "Bar"
		bar.Rotation = rot
	end

	statusLabel = Instance.new("TextLabel")
	statusLabel.BackgroundTransparency = 1
	statusLabel.Size = UDim2.fromOffset(160, 20)
	statusLabel.AnchorPoint = Vector2.new(0.5, 0)
	statusLabel.Position = UDim2.new(0.5, 0, 1, 4)
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextSize = 14
	statusLabel.TextColor3 = Color3.fromRGB(255, 230, 120)
	statusLabel.TextStrokeTransparency = 0.5
	statusLabel.Text = ""
	statusLabel.Parent = crosshair

	fireButton = Instance.new("TextButton")
	fireButton.Name = "FireButton"
	styleButton(fireButton, "FIRE", UDim2.new(1, -90, 1, -110), UDim2.fromOffset(84, 84))
	reloadButton = Instance.new("TextButton")
	reloadButton.Name = "ReloadButton"
	styleButton(reloadButton, "RELOAD", UDim2.new(1, -190, 1, -70), UDim2.fromOffset(64, 64))
	reloadButton.TextSize = 13
end

local function updateStatus()
	if reloading then
		statusLabel.Text = "RELOADING..."
	elseif ammo <= 0 then
		statusLabel.Text = "EMPTY - PRESS R"
	else
		statusLabel.Text = ""
	end
end

local function flashHitmarker(isHeadshot: boolean, isKill: boolean)
	if not hitmarker then
		return
	end
	local color = if isKill then Color3.fromRGB(255, 50, 50) elseif isHeadshot then Color3.fromRGB(255, 220, 90) else Color3.new(1, 1, 1)
	hitmarker.Visible = true
	for _, bar in hitmarker:GetChildren() do
		if bar:IsA("Frame") then
			bar.BackgroundColor3 = color
			bar.BackgroundTransparency = 0
			TweenService:Create(bar, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
		end
	end
	local snd = Instance.new("Sound")
	snd.SoundId = "rbxasset://sounds/electronicpingshort.wav"
	snd.Volume = if isKill then 0.6 else 0.3
	snd.Parent = gui
	snd:Play()
	Debris:AddItem(snd, 2)
end

-- Aiming -----------------------------------------------------------------------------------------

local function getAimPoint(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local pos: Vector2
	if centerAim then
		pos = camera.ViewportSize / 2
	else
		pos = UserInputService:GetMouseLocation()
	end
	local ray = camera:ViewportPointToRay(pos.X, pos.Y)
	local exclude: { Instance } = {}
	local character = player.Character
	if character then
		table.insert(exclude, character)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local seat = humanoid and humanoid.SeatPart
		local vehicle = seat and seat:FindFirstAncestorOfClass("Model")
		if vehicle and vehicle ~= character then
			table.insert(exclude, vehicle)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	local result = Workspace:Raycast(ray.Origin, ray.Direction * FAR_DISTANCE, params)
	if result then
		return result.Position
	end
	return ray.Origin + ray.Direction * FAR_DISTANCE
end

local function isAlive(): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function requestReload()
	local now = os.clock()
	if not rifle or reloading or ammo >= Config.Rifle.MagazineSize then
		return
	end
	if now - lastReloadRequest < 0.4 then
		return
	end
	lastReloadRequest = now
	reloadRemote:FireServer()
end

local function tryFire()
	if not rifle or not isAlive() then
		return
	end
	if reloading then
		return
	end
	if ammo <= 0 then
		requestReload()
		return
	end
	local now = os.clock()
	if now < lastFire + FIRE_INTERVAL then
		return
	end
	local aim = getAimPoint()
	if not aim then
		return
	end
	lastFire = if now - lastFire > FIRE_INTERVAL * 2 then now else lastFire + FIRE_INTERVAL
	ammo -= 1
	updateStatus()
	fireRemote:FireServer(aim)
end

local function wantsFire(): boolean
	return mouseHeld or touchHeld or padHeld
end

local function onRender()
	-- crosshair position
	local camera = Workspace.CurrentCamera
	if centerAim and camera then
		local c = camera.ViewportSize / 2
		crosshair.Position = UDim2.fromOffset(c.X, c.Y)
	else
		local m = UserInputService:GetMouseLocation()
		crosshair.Position = UDim2.fromOffset(m.X, m.Y)
	end
	if wantsFire() then
		tryFire()
	end
end

-- Equip handling ---------------------------------------------------------------------------------

local function setRifle(tool: Tool?)
	if tool == rifle then
		return
	end
	rifle = tool
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if tool then
		UserInputService.MouseIconEnabled = false
		crosshair.Visible = true
		updateStatus()
		local touchUi = UserInputService.TouchEnabled
		fireButton.Visible = touchUi
		reloadButton.Visible = touchUi
		renderConn = RunService.RenderStepped:Connect(onRender)
	else
		UserInputService.MouseIconEnabled = true
		crosshair.Visible = false
		fireButton.Visible = false
		reloadButton.Visible = false
		mouseHeld = false
		touchHeld = false
		padHeld = false
		touchInput = nil
	end
end

local function clearCharConns()
	for _, c in charConns do
		c:Disconnect()
	end
	table.clear(charConns)
end

local function watchCharacter(character: Model)
	clearCharConns()
	local function consider(child: Instance)
		if child:IsA("Tool") and child.Name == Config.Rifle.ToolName then
			setRifle(child)
		end
	end
	table.insert(charConns, character.ChildAdded:Connect(consider))
	table.insert(
		charConns,
		character.ChildRemoved:Connect(function(child)
			if child == rifle then
				setRifle(nil)
			end
		end)
	)
	for _, child in character:GetChildren() do
		consider(child)
	end
end

-- Lifecycle --------------------------------------------------------------------------------------

function WeaponController.Init(_self) end

function WeaponController.Start(_self)
	fireRemote = Remotes.event("FireWeapon")
	reloadRemote = Remotes.event("ReloadWeapon")
	buildGui()

	centerAim = UserInputService:GetLastInputType() == Enum.UserInputType.Touch
		or UserInputService:GetLastInputType().Name:find("Gamepad") ~= nil

	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		if inputType == Enum.UserInputType.Touch or inputType.Name:find("Gamepad") ~= nil then
			centerAim = true
		elseif inputType == Enum.UserInputType.MouseMovement or inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Keyboard then
			centerAim = false
		end
	end)

	Remotes.event("AmmoUpdate").OnClientEvent:Connect(function(newAmmo, isReloading)
		if type(newAmmo) == "number" then
			ammo = newAmmo
		end
		reloading = isReloading == true
		updateStatus()
	end)

	Remotes.event("HitMarker").OnClientEvent:Connect(function(isHeadshot, isKill)
		flashHitmarker(isHeadshot == true, isKill == true)
	end)

	Remotes.event("WeaponFx").OnClientEvent:Connect(function(shooter, origin, hitPos)
		if typeof(origin) ~= "Vector3" or typeof(hitPos) ~= "Vector3" then
			return
		end
		local dist = (hitPos - origin).Magnitude
		if dist < 0.5 or dist ~= dist or dist == math.huge then
			return
		end
		local parent = Workspace.CurrentCamera or Workspace
		local tracer = Instance.new("Part")
		tracer.Name = "Tracer"
		tracer.Anchored = true
		tracer.CanCollide = false
		tracer.CanQuery = false
		tracer.CanTouch = false
		tracer.CastShadow = false
		tracer.Material = Enum.Material.Neon
		tracer.Color = Color3.fromRGB(255, 225, 130)
		tracer.Size = Vector3.new(0.08, 0.08, dist)
		tracer.CFrame = CFrame.lookAt(origin, hitPos) * CFrame.new(0, 0, -dist / 2)
		tracer.Parent = parent
		TweenService:Create(tracer, TweenInfo.new(0.08), { Transparency = 1 }):Play()
		Debris:AddItem(tracer, 0.1)

		-- Muzzle flash
		if typeof(shooter) == "Instance" and shooter:IsA("Player") then
			local character = shooter.Character
			local tool = character and character:FindFirstChild(Config.Rifle.ToolName)
			local handle = tool and tool:FindFirstChild("Handle")
			local muzzle = handle and handle:FindFirstChild("Muzzle")
			if muzzle and muzzle:IsA("Attachment") then
				local light = Instance.new("PointLight")
				light.Color = Color3.fromRGB(255, 190, 90)
				light.Brightness = 3
				light.Range = 10
				light.Parent = muzzle
				Debris:AddItem(light, 0.05)
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not rifle then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if not gameProcessed then
				mouseHeld = true
				centerAim = false
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and hum.SeatPart and hum.SeatPart:IsA("VehicleSeat") then
				return -- R2 is heli climb while seated in a vehicle
			end
			padHeld = true
			centerAim = true
		elseif input.KeyCode == Enum.KeyCode.R then
			if not gameProcessed then
				requestReload()
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonX then
			requestReload()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseHeld = false
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			padHeld = false
		end
		if touchInput and input == touchInput then
			touchHeld = false
			touchInput = nil
		end
	end)

	fireButton.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			touchHeld = true
			touchInput = input
			centerAim = true
		end
	end)
	reloadButton.Activated:Connect(requestReload)

	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(function()
		clearCharConns()
		setRifle(nil)
		ammo = Config.Rifle.MagazineSize
		reloading = false
	end)
	if player.Character then
		watchCharacter(player.Character)
	end
end

return WeaponController
