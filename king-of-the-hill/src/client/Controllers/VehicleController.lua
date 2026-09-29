-- VehicleController: client-side helicopter flight (the pilot is the network owner) + control hint / touch buttons.
-- Cars are driven server-side by VehicleService from VehicleSeat.ThrottleFloat/SteerFloat, so nothing is needed here.
--
-- Space is bound at high priority (sunk) while piloting so it climbs instead of ejecting the pilot. Press F to exit
-- (on touch, the normal Jump button exits; on gamepad, ButtonA exits).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local VehicleController = {}

local localPlayer = Players.LocalPlayer
local CEILING = 400
local GROUND_CLEARANCE = 3.6 -- body center height above ground at which we stop descending

local held = { Up = false, Down = false }
local keys = { Throttle = 0, Steer = 0 }
local active = nil
local hint: TextLabel? = nil
local touchGui: ScreenGui? = nil
local touchButtons: { TextButton } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function heliCfg()
	local c = Config.Vehicles.Helicopter
	return c.MaxSpeed or 90, c.ClimbSpeed or 35, c.YawSpeed or 1.6, c.MaxTilt or math.rad(20)
end

local function setVisible(on: boolean)
	if hint then
		hint.Visible = on
	end
	for _, b in touchButtons do
		b.Visible = on and UserInputService.TouchEnabled
	end
end

local function moveHandler(_name, state, input)
	local down = state == Enum.UserInputState.Begin
	local k = input.KeyCode
	if k == Enum.KeyCode.W then
		keys.Throttle = down and 1 or (keys.Throttle == 1 and 0 or keys.Throttle)
	elseif k == Enum.KeyCode.S then
		keys.Throttle = down and -1 or (keys.Throttle == -1 and 0 or keys.Throttle)
	elseif k == Enum.KeyCode.D then
		keys.Steer = down and 1 or (keys.Steer == 1 and 0 or keys.Steer)
	elseif k == Enum.KeyCode.A then
		keys.Steer = down and -1 or (keys.Steer == -1 and 0 or keys.Steer)
	end
	return Enum.ContextActionResult.Pass
end

local function flightKeyHandler(_name, state, input)
	local down = state == Enum.UserInputState.Begin
	local k = input.KeyCode
	if k == Enum.KeyCode.Space or k == Enum.KeyCode.ButtonR2 then
		held.Up = down
	elseif k == Enum.KeyCode.LeftControl or k == Enum.KeyCode.Q or k == Enum.KeyCode.ButtonL2 then
		held.Down = down
	elseif k == Enum.KeyCode.F and down and active then
		local hum = active.humanoid
		hum.Sit = false
		hum.Jump = true
	end
	return Enum.ContextActionResult.Sink
end

local function findActive(): any
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not (seat and seat:IsA("VehicleSeat")) then
		return nil
	end
	local model = seat.Parent
	if not (model and model:IsA("Model") and model:GetAttribute("VehicleKind") == "Helicopter") then
		return nil
	end
	local lv = model:FindFirstChild("FlightVelocity", true)
	local ao = model:FindFirstChild("FlightOrient", true)
	local body = model.PrimaryPart
	if not (lv and ao and body and lv:IsA("LinearVelocity") and ao:IsA("AlignOrientation")) then
		return nil
	end
	local look = body.CFrame.LookVector
	return {
		humanoid = hum,
		seat = seat,
		model = model,
		body = body,
		lv = lv,
		ao = ao,
		char = char,
		yaw = math.atan2(-look.X, -look.Z),
		speed = 0,
		vy = 0,
		pitch = 0,
		roll = 0,
	}
end

local function begin(state)
	active = state
	held.Up, held.Down = false, false
	keys.Throttle, keys.Steer = 0, 0
	rayParams.FilterDescendantsInstances = { state.model, state.char }
	ContextActionService:BindActionAtPriority(
		"HeliFlightKeys",
		flightKeyHandler,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Space,
		Enum.KeyCode.LeftControl,
		Enum.KeyCode.Q,
		Enum.KeyCode.F,
		Enum.KeyCode.ButtonR2,
		Enum.KeyCode.ButtonL2
	)
	ContextActionService:BindActionAtPriority(
		"HeliMoveKeys",
		moveHandler,
		false,
		Enum.ContextActionPriority.Low.Value,
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D
	)
	setVisible(true)
end

local function finish()
	if active then
		ContextActionService:UnbindAction("HeliFlightKeys")
		ContextActionService:UnbindAction("HeliMoveKeys")
	end
	active = nil
	held.Up, held.Down = false, false
	setVisible(false)
end

local function step(dt: number)
	local a = active
	local maxSpeed, climbSpeed, yawSpeed, maxTilt = heliCfg()

	local throttle = a.seat.ThrottleFloat
	local steer = a.seat.SteerFloat
	if math.abs(keys.Throttle) > math.abs(throttle) then
		throttle = keys.Throttle
	end
	if math.abs(keys.Steer) > math.abs(steer) then
		steer = keys.Steer
	end
	local vertical = (held.Up and 1 or 0) - (held.Down and 1 or 0)

	-- yaw: D (steer +1) turns clockwise seen from above = decreasing yaw
	a.yaw -= steer * yawSpeed * dt
	local heading = CFrame.Angles(0, a.yaw, 0)
	local fwd = heading.LookVector

	-- smoothed forward speed (reverse is slower)
	local targetSpeed = throttle * maxSpeed * (throttle < 0 and 0.5 or 1)
	a.speed += (targetSpeed - a.speed) * (1 - math.exp(-2.5 * dt))

	-- smoothed vertical speed; zero input holds altitude
	local targetVy = vertical * climbSpeed
	a.vy += (targetVy - a.vy) * (1 - math.exp(-4 * dt))
	local pos = a.body.Position
	if pos.Y > CEILING and a.vy > 0 then
		a.vy = 0
	end
	if a.vy < 0 then
		local hit = Workspace:Raycast(pos, Vector3.new(0, -12, 0), rayParams)
		if hit and hit.Distance < GROUND_CLEARANCE then
			a.vy = 0
		end
	end

	a.lv.VectorVelocity = Vector3.new(fwd.X * a.speed, a.vy, fwd.Z * a.speed)

	-- visual tilt: nose down when going forward (negative rotation about X), bank into turns
	local k = 1 - math.exp(-6 * dt)
	a.pitch += (-(a.speed / maxSpeed) * maxTilt - a.pitch) * k
	a.roll += (-steer * maxTilt - a.roll) * k
	a.ao.CFrame = heading * CFrame.Angles(a.pitch, 0, 0) * CFrame.Angles(0, 0, a.roll)
end

local function onHeartbeat(dt: number)
	dt = math.min(dt, 0.1)
	if active then
		local a = active
		local stillSeated = a.humanoid.Parent ~= nil
			and a.humanoid.SeatPart == a.seat
			and a.model.Parent ~= nil
			and a.lv.Parent ~= nil
		if stillSeated then
			step(dt)
			return
		end
		finish()
	end
	local found = findActive()
	if found then
		begin(found)
	end
end

local function makeButton(parent: Instance, text: string, position: UDim2, flag: string): TextButton
	local b = Instance.new("TextButton")
	b.Name = text
	b.Text = text
	b.Size = UDim2.fromOffset(84, 64)
	b.Position = position
	b.AnchorPoint = Vector2.new(1, 1)
	b.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	b.BackgroundTransparency = 0.35
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 20
	b.AutoButtonColor = true
	b.Visible = false
	b.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = b
	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			held[flag] = true
		end
	end)
	b.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			held[flag] = false
		end
	end)
	return b
end

function VehicleController.Init(_self) end

function VehicleController.Start(_self)
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "VehicleHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = playerGui
	touchGui = gui

	local label = Instance.new("TextLabel")
	label.Name = "ControlHint"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -16)
	label.Size = UDim2.fromOffset(420, 24)
	label.BackgroundTransparency = 0.5
	label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.Text = "W/S move, A/D turn, Space up, Ctrl/Q down (F exit)"
	label.Visible = false
	label.Parent = gui
	hint = label

	touchButtons = {
		makeButton(gui, "UP", UDim2.new(1, -24, 1, -110), "Up"),
		makeButton(gui, "DOWN", UDim2.new(1, -24, 1, -36), "Down"),
	}

	RunService.Heartbeat:Connect(onHeartbeat)
end

return VehicleController
