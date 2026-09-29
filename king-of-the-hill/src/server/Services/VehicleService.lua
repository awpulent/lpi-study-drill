-- VehicleService: builds Cars and Helicopters entirely from Parts + constraints.
--
-- DESIGN NOTES
-- CAR (server-driven, 4-wheel drive, real steering knuckles):
--   * Chassis (7x1.5x12, density 6, low CoM) is the root. Decor (body, cabin, glass, lights, seats) is Massless and welded.
--   * Every wheel is a Cylinder (axis X, friction 2, friction weight 100) on a HingeConstraint Motor (all 4 driven).
--   * Front wheels hang on a small "knuckle" part: chassis -> knuckle is a HingeConstraint Servo about Y (steering),
--     knuckle -> wheel is the Motor hinge about X.
--   * A single server Heartbeat loop reads VehicleSeat.ThrottleFloat / SteerFloat (replicated from the driver, who is the
--     network owner) and writes the hinge properties. Constraint property writes on the server replicate and are honoured
--     by the driver's physics simulation, so the car is driven server-side consistently.
--   * The sign conventions of hinge motor / servo are self-calibrated at runtime (see DRIVE_SIGN / STEER_SIGN), so a wrong
--     assumption about hinge axis direction fixes itself within about 0.6 s of first driving.
--   * Flip recovery: upside down (UpVector.Y < 0.25) and slow for 3 s -> re-placed upright.
-- HELICOPTER (client-driven, see VehicleController):
--   * Body (floor slab, density 5 => mass 270) is the only massive part of the main assembly. All decor is Massless.
--   * RootAttachment on the body carries LinearVelocity (Vector/World) and AlignOrientation (OneAttachment).
--   * Rotors are separate light assemblies on HingeConstraint Motors (spin only while occupied).
--   * Unoccupied: constraints disabled, rests on skids. Pilot sits: constraints enabled, network owner = pilot, the client
--     writes VectorVelocity / AlignOrientation.CFrame each frame. Pilot leaves: ownership back to server, slow descent
--     until grounded, then constraints disabled.
--
-- Public API tolerates both VehicleService.Fn(...) and VehicleService:Fn(...) call styles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local VehicleService = {}

-- ---------------------------------------------------------------- constants
local WHEEL_RADIUS = 1.5
local WHEEL_WIDTH = 1.5
local HELI_REST_HEIGHT = 3.2 -- body center to ground when skids touch (2.55) + margin
local HELI_LAND_SPEED = 8
local ROTOR_SPEED = 32
local TAIL_ROTOR_SPEED = 45
local FLIP_TIME = 3
local KILL_Y = -150
local NEUTRAL_COLOR = Color3.fromRGB(163, 162, 165)

-- Runtime-calibrated sign conventions (shared by all cars once learned).
local DRIVE_SIGN = -1 -- wheel angular velocity about chassis +X needed to roll toward -Z (forward)
local DRIVE_LOCKED = false -- set once a car has been seen driving the right way; stops further flips
local STEER_LOCKED = false
local STEER_SIGN = 1 -- servo TargetAngle sign (positive = counter-clockwise seen from above = left)

-- ---------------------------------------------------------------- state
local vehiclesFolder: Folder? = nil
local records = {} -- [Model] = record
local ownerVehicle = {} -- [userId] = Model

-- ---------------------------------------------------------------- helpers
local function newMaid()
	return { items = {} }
end

local function maidGive(maid, item)
	table.insert(maid.items, item)
	return item
end

local function maidClean(maid)
	for _, item in maid.items do
		if typeof(item) == "RBXScriptConnection" then
			item:Disconnect()
		elseif typeof(item) == "Instance" then
			item:Destroy()
		elseif type(item) == "function" then
			pcall(item)
		end
	end
	table.clear(maid.items)
end

-- Calls a sibling service function whether it was declared with '.' or ':'.
local function callService(mod, fname, ...)
	local fn = mod[fname]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, nparams, isVararg = pcall(debug.info, fn, "a")
	if ok and not isVararg and nparams == select("#", ...) + 1 then
		return fn(mod, ...)
	end
	return fn(...)
end

local function stripSelf(...)
	if (...) == VehicleService then
		return select(2, ...)
	end
	return ...
end

local function approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

local function playerFromHumanoid(hum: Instance?): Player?
	if hum and hum.Parent then
		return Players:GetPlayerFromCharacter(hum.Parent)
	end
	return nil
end

local function teamInfo(player: Player): (string, Color3)
	local name = player.Team and player.Team.Name or nil
	if not name then
		local ok, res = pcall(function()
			return callService(require(script.Parent.TeamService), "GetTeamName", player)
		end)
		if ok and type(res) == "string" then
			name = res
		end
	end
	for _, t in Config.Teams do
		if t.Name == name then
			return t.Name, t.Color
		end
	end
	return name or "Neutral", NEUTRAL_COLOR
end

local function findPad(teamName: string, kind: string): BasePart?
	local map = Workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	local base = bases and bases:FindFirstChild(teamName)
	local pads = base and base:FindFirstChild("VehiclePads")
	local pad = pads and pads:FindFirstChild(kind == "Car" and "CarPad" or "HeliPad")
	if pad and pad:IsA("BasePart") then
		return pad
	end
	return nil
end

local function isFree(position: Vector3): boolean
	for model in records do
		if model.Parent and (model:GetPivot().Position - position).Magnitude < 10 then
			return false
		end
	end
	return true
end

local function computeSpawnCFrame(pad: BasePart): CFrame
	local base = pad.Position + Vector3.new(0, pad.Size.Y / 2 + 4, 0)
	local look = Vector3.new(pad.CFrame.LookVector.X, 0, pad.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	end
	look = look.Unit
	local right = look:Cross(Vector3.yAxis)
	local chosen = base
	for _, offset in { 0, 14, -14, 28, -28, 42, -42 } do
		local candidate = base + right * offset
		chosen = candidate
		if isFree(candidate) then
			break
		end
	end
	return CFrame.lookAt(chosen, chosen + look)
end

local function uprightCFrame(part: BasePart): CFrame
	local look = part.CFrame.LookVector
	return CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
end

-- ---------------------------------------------------------------- part builders
local function newPart(rec, name, size, cf, color, material, opts, weldRoot)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if opts then
		for k, v in opts do
			(p :: any)[k] = v
		end
	end
	p.Parent = rec.model
	table.insert(rec.parts, p)
	if weldRoot then
		table.insert(rec.pendingWelds, { p, weldRoot })
	end
	return p
end

-- A slanted slab from `bottom` to `top` (model-local points); thin axis is perpendicular to the slope.
local function newSlab(rec, name, width, bottom, top, color, material, opts, weldRoot)
	local mid = (bottom + top) / 2
	local len = (top - bottom).Magnitude
	return newPart(rec, name, Vector3.new(width, 0.15, len), CFrame.lookAt(mid, top), color, material, opts, weldRoot)
end

local function newSeat(rec, className, name, cf, root)
	local s = Instance.new(className)
	s.Name = name
	s.Size = Vector3.new(2, 1, 2)
	s.CFrame = cf
	s.Color = Color3.fromRGB(50, 52, 58)
	s.Material = Enum.Material.Fabric
	s.Anchored = true
	s.Massless = true
	s.TopSurface = Enum.SurfaceType.Smooth
	s.BottomSurface = Enum.SurfaceType.Smooth
	s.Parent = rec.model
	table.insert(rec.parts, s)
	table.insert(rec.pendingWelds, { s, root })
	table.insert(rec.seats, s)
	return s
end

local function newAttachment(parent: Instance, name: string, cf: CFrame): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = cf
	a.Parent = parent
	return a
end

local AXIS_TO_Y = CFrame.Angles(0, 0, math.rad(90)) -- rotates an attachment's X axis onto Y

-- ---------------------------------------------------------------- CAR
local WHEEL_DEFS = {
	{ name = "FL", pos = Vector3.new(-4.4, -0.5, -4), steer = true },
	{ name = "FR", pos = Vector3.new(4.4, -0.5, -4), steer = true },
	{ name = "RL", pos = Vector3.new(-4.4, -0.5, 4), steer = false },
	{ name = "RR", pos = Vector3.new(4.4, -0.5, 4), steer = false },
}

local function buildCar(rec, teamColor: Color3)
	local cfg = Config.Vehicles.Car
	local dark = Color3.fromRGB(35, 35, 40)
	local glassColor = Color3.fromRGB(150, 200, 230)

	local chassis = newPart(rec, "Chassis", Vector3.new(7, 1.5, 12), CFrame.new(), dark, Enum.Material.Metal)
	chassis.Massless = false
	chassis.CanCollide = true
	chassis.CanTouch = true
	chassis.CustomPhysicalProperties = PhysicalProperties.new(6, 0.3, 0, 1, 1)
	rec.model.PrimaryPart = chassis
	rec.primary = chassis

	local function decor(name, size, pos, color, material, opts)
		return newPart(rec, name, size, CFrame.new(pos), color, material, opts, chassis)
	end

	-- body shell
	local hood = decor("Hood", Vector3.new(6.6, 0.9, 3.5), Vector3.new(0, 1.2, -4.25), teamColor, Enum.Material.Metal)
	decor("Trunk", Vector3.new(6.6, 0.9, 1.4), Vector3.new(0, 1.2, 5.3), teamColor, Enum.Material.Metal)
	decor("DoorL", Vector3.new(0.3, 1.6, 7.1), Vector3.new(-3.3, 1.55, 1.05), teamColor, Enum.Material.Metal)
	decor("DoorR", Vector3.new(0.3, 1.6, 7.1), Vector3.new(3.3, 1.55, 1.05), teamColor, Enum.Material.Metal)
	-- cabin
	decor("Roof", Vector3.new(6.8, 0.4, 7.1), Vector3.new(0, 5.6, 1.05), teamColor, Enum.Material.Metal)
	for _, x in { -3.3, 3.3 } do
		for _, z in { -2.3, 4.4 } do
			decor("Pillar", Vector3.new(0.4, 4.65, 0.4), Vector3.new(x, 3.075, z), teamColor, Enum.Material.Metal)
		end
	end
	-- glass
	local glassOpts = { Transparency = 0.5, Reflectance = 0.1 }
	newSlab(rec, "Windshield", 6.4, Vector3.new(0, 1.65, -2.5), Vector3.new(0, 5.4, -1.9), glassColor, Enum.Material.Glass, glassOpts, chassis)
	newSlab(rec, "RearGlass", 6.4, Vector3.new(0, 1.65, 4.6), Vector3.new(0, 5.4, 4.0), glassColor, Enum.Material.Glass, glassOpts, chassis)
	decor("GlassL", Vector3.new(0.1, 3.0, 6.8), Vector3.new(-3.4, 3.85, 1.05), glassColor, Enum.Material.Glass, glassOpts)
	decor("GlassR", Vector3.new(0.1, 3.0, 6.8), Vector3.new(3.4, 3.85, 1.05), glassColor, Enum.Material.Glass, glassOpts)
	-- lights
	for _, x in { -2.3, 2.3 } do
		local head = decor("Headlight", Vector3.new(1.2, 0.6, 0.3), Vector3.new(x, 1.2, -6.1), Color3.fromRGB(255, 244, 200), Enum.Material.Neon)
		local light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Front
		light.Angle = 60
		light.Range = 40
		light.Brightness = 2
		light.Parent = head
		decor("Taillight", Vector3.new(1, 0.5, 0.3), Vector3.new(x, 1.2, 6.1), Color3.fromRGB(255, 40, 40), Enum.Material.Neon)
	end
	rec.fxParent = hood

	-- seats (facing -Z)
	rec.driverSeat = newSeat(rec, "VehicleSeat", "DriverSeat", CFrame.new(-1.5, 1.25, -1), chassis)
	local drv = rec.driverSeat
	drv.MaxSpeed = cfg.MaxSpeed
	drv.Torque = cfg.Torque
	drv.TurnSpeed = cfg.TurnSpeed
	drv.HeadsUpDisplay = false
	newSeat(rec, "Seat", "Passenger1", CFrame.new(1.5, 1.25, -1), chassis)
	newSeat(rec, "Seat", "Passenger2", CFrame.new(-1.5, 1.25, 3.5), chassis)
	newSeat(rec, "Seat", "Passenger3", CFrame.new(1.5, 1.25, 3.5), chassis)

	-- wheels + knuckles
	rec.motors = {}
	rec.servos = {}
	for _, def in WHEEL_DEFS do
		local wheel = newPart(
			rec,
			"Wheel" .. def.name,
			Vector3.new(WHEEL_WIDTH, WHEEL_RADIUS * 2, WHEEL_RADIUS * 2),
			CFrame.new(def.pos),
			Color3.fromRGB(25, 25, 25),
			Enum.Material.SmoothPlastic,
			{ Shape = Enum.PartType.Cylinder }
		)
		wheel.Massless = false
		wheel.CanCollide = true
		wheel.CanTouch = true
		wheel.CustomPhysicalProperties = PhysicalProperties.new(4, 2, 0, 100, 1)
		newPart(
			rec,
			"Hub" .. def.name,
			Vector3.new(1.6, 0.5, 2.4),
			CFrame.new(def.pos),
			Color3.fromRGB(200, 200, 205),
			Enum.Material.Metal,
			nil,
			wheel
		)
		local knuckle
		if def.steer then
			knuckle = newPart(rec, "Knuckle" .. def.name, Vector3.new(1, 1, 1), CFrame.new(def.pos), dark)
			knuckle.Massless = false
			knuckle.CustomPhysicalProperties = PhysicalProperties.new(4, 0.3, 0, 1, 1)
		end
		table.insert(rec.pendingHinges, { def = def, wheel = wheel, knuckle = knuckle })
	end
end

local function assembleCar(rec)
	local cfg = Config.Vehicles.Car
	local chassis = rec.primary
	local torque = cfg.Torque
	rec.steerAngle = cfg.SteerAngle or math.rad(30)
	for _, h in rec.pendingHinges do
		local def, wheel, knuckle = h.def, h.wheel, h.knuckle
		local motor = Instance.new("HingeConstraint")
		motor.Name = "Drive" .. def.name
		motor.ActuatorType = Enum.ActuatorType.Motor
		motor.MotorMaxTorque = torque
		motor.MotorMaxAcceleration = 10000
		motor.AngularVelocity = 0
		if knuckle then
			local servo = Instance.new("HingeConstraint")
			servo.Name = "Steer" .. def.name
			servo.Attachment0 = newAttachment(chassis, "SteerA" .. def.name, CFrame.new(def.pos) * AXIS_TO_Y)
			servo.Attachment1 = newAttachment(knuckle, "SteerB", AXIS_TO_Y)
			servo.ActuatorType = Enum.ActuatorType.Servo
			servo.ServoMaxTorque = torque * 5
			servo.AngularSpeed = math.max(cfg.TurnSpeed * 4, 3)
			servo.LimitsEnabled = true
			servo.LowerAngle = -45
			servo.UpperAngle = 45
			servo.TargetAngle = 0
			servo.Parent = chassis
			table.insert(rec.servos, servo)
			motor.Attachment0 = newAttachment(knuckle, "DriveA", CFrame.new())
		else
			motor.Attachment0 = newAttachment(chassis, "DriveA" .. def.name, CFrame.new(def.pos))
		end
		motor.Attachment1 = newAttachment(wheel, "DriveB", CFrame.new())
		motor.Parent = wheel
		table.insert(rec.motors, motor)
		table.insert(rec.physParts, wheel)
		if knuckle then
			table.insert(rec.physParts, knuckle)
		end
	end
	table.insert(rec.physParts, chassis)
	rec.throttle = 0
	rec.steer = 0
	rec.flipT = 0
	rec.calDrive = 0
	rec.calSteer = 0
end

-- ---------------------------------------------------------------- HELICOPTER
local function buildHelicopter(rec, teamColor: Color3)
	local dark = Color3.fromRGB(35, 35, 40)
	local grey = Color3.fromRGB(90, 92, 98)
	local glassColor = Color3.fromRGB(150, 200, 230)
	local glassOpts = { Transparency = 0.5, Reflectance = 0.1 }

	local body = newPart(rec, "Body", Vector3.new(5, 1.2, 9), CFrame.new(), teamColor, Enum.Material.Metal)
	body.Massless = false
	body.CanCollide = true
	body.CanTouch = true
	body.CustomPhysicalProperties = PhysicalProperties.new(5, 0.5, 0, 1, 1) -- mass = 54 studs^3 * 5 = 270
	rec.model.PrimaryPart = body
	rec.primary = body

	local function decor(name, size, pos, color, material, opts)
		return newPart(rec, name, size, CFrame.new(pos), color, material, opts, body)
	end

	decor("Nose", Vector3.new(4.6, 1.6, 1.5), Vector3.new(0, 1.4, -3.75), teamColor, Enum.Material.Metal)
	local engine = decor("Engine", Vector3.new(4.6, 2.4, 1.5), Vector3.new(0, 1.8, 3.75), teamColor, Enum.Material.Metal)
	decor("SillL", Vector3.new(0.3, 1.0, 6), Vector3.new(-2.35, 1.1, 0), teamColor, Enum.Material.Metal)
	decor("SillR", Vector3.new(0.3, 1.0, 6), Vector3.new(2.35, 1.1, 0), teamColor, Enum.Material.Metal)
	decor("Roof", Vector3.new(5, 0.4, 6.2), Vector3.new(0, 5.5, 0.1), teamColor, Enum.Material.Metal)
	for _, x in { -2.3, 2.3 } do
		for _, z in { -3, 3 } do
			decor("Pillar", Vector3.new(0.4, 4.7, 0.4), Vector3.new(x, 2.95, z), teamColor, Enum.Material.Metal)
		end
	end
	newSlab(rec, "Canopy", 4.6, Vector3.new(0, 2.2, -3.9), Vector3.new(0, 5.3, -3.0), glassColor, Enum.Material.Glass, glassOpts, body)
	decor("GlassL", Vector3.new(0.1, 3.1, 6), Vector3.new(-2.5, 3.75, 0), glassColor, Enum.Material.Glass, glassOpts)
	decor("GlassR", Vector3.new(0.1, 3.1, 6), Vector3.new(2.5, 3.75, 0), glassColor, Enum.Material.Glass, glassOpts)
	rec.fxParent = engine

	-- tail
	decor("TailBoom", Vector3.new(1.2, 1.2, 8), Vector3.new(0, 2.3, 8.5), teamColor, Enum.Material.Metal)
	local fin = decor("TailFin", Vector3.new(0.3, 3, 1.6), Vector3.new(0, 3.8, 12), teamColor, Enum.Material.Metal)
	decor("TailStabilizer", Vector3.new(4, 0.2, 1.2), Vector3.new(0, 2.3, 11.6), grey, Enum.Material.Metal)

	-- skids (runners collide, struts do not)
	for _, x in { -2.6, 2.6 } do
		decor("SkidRunner", Vector3.new(0.4, 0.3, 8), Vector3.new(x, -2.4, 0.3), dark, Enum.Material.Metal, { CanCollide = true })
		for _, z in { -2.2, 2.8 } do
			decor("SkidStrut", Vector3.new(0.3, 1.8, 0.3), Vector3.new(x, -1.5, z), dark, Enum.Material.Metal)
		end
	end

	-- seats
	rec.driverSeat = newSeat(rec, "VehicleSeat", "PilotSeat", CFrame.new(-1.1, 1.1, -1.8), body)
	rec.driverSeat.HeadsUpDisplay = false
	rec.driverSeat.Torque = 0
	rec.driverSeat.MaxSpeed = 0
	rec.driverSeat.TurnSpeed = 0
	newSeat(rec, "Seat", "Passenger1", CFrame.new(1.1, 1.1, -1.8), body)
	newSeat(rec, "Seat", "Passenger2", CFrame.new(-1.1, 1.1, 1.5), body)
	newSeat(rec, "Seat", "Passenger3", CFrame.new(1.1, 1.1, 1.5), body)

	-- main rotor: mast (welded to body) + hub with two crossed blades (separate light assembly on a Motor hinge)
	local mast = decor("Mast", Vector3.new(0.8, 1.0, 0.8), Vector3.new(0, 6.2, 0.1), dark, Enum.Material.Metal)
	local rotorProps = PhysicalProperties.new(0.3, 0.3, 0, 1, 1)
	local hub = newPart(rec, "RotorHub", Vector3.new(1, 0.4, 1), CFrame.new(0, 6.9, 0.1), dark, Enum.Material.Metal)
	hub.Massless = false
	hub.CustomPhysicalProperties = rotorProps
	for i, size in { Vector3.new(16, 0.15, 0.9), Vector3.new(0.9, 0.15, 16) } do
		local blade = newPart(rec, "RotorBlade" .. i, size, CFrame.new(0, 7.15, 0.1), grey, Enum.Material.Metal, nil, hub)
		blade.Massless = false
		blade.CustomPhysicalProperties = rotorProps
	end
	-- tail rotor (axis X) on the fin
	local thub = newPart(rec, "TailRotorHub", Vector3.new(0.4, 0.4, 0.4), CFrame.new(0.55, 3.3, 12), dark, Enum.Material.Metal)
	thub.Massless = false
	thub.CustomPhysicalProperties = rotorProps
	for i, size in { Vector3.new(0.1, 3, 0.4), Vector3.new(0.1, 0.4, 3) } do
		local blade = newPart(rec, "TailBlade" .. i, size, CFrame.new(0.55, 3.3, 12), grey, Enum.Material.Metal, nil, thub)
		blade.Massless = false
		blade.CustomPhysicalProperties = rotorProps
	end
	rec.rotorParts = { mast = mast, hub = hub, fin = fin, thub = thub, mastLocal = mast.Position, hubLocal = hub.Position, finLocal = fin.Position, thubLocal = thub.Position }
end

local function assembleHelicopter(rec)
	local cfg = Config.Vehicles.Helicopter
	local body = rec.primary
	local rp = rec.rotorParts

	-- rotor hinges
	local function motorHinge(name, part0, att0cf, part1, att1cf, maxAccel)
		local h = Instance.new("HingeConstraint")
		h.Name = name
		h.Attachment0 = newAttachment(part0, name .. "A", att0cf)
		h.Attachment1 = newAttachment(part1, name .. "B", att1cf)
		h.ActuatorType = Enum.ActuatorType.Motor
		h.MotorMaxTorque = 5000
		h.MotorMaxAcceleration = maxAccel
		h.AngularVelocity = 0
		h.Parent = part1
		return h
	end
	rec.mainHinge = motorHinge("MainRotorHinge", rp.mast, CFrame.new(0, rp.hubLocal.Y - rp.mastLocal.Y, 0) * AXIS_TO_Y, rp.hub, AXIS_TO_Y, 25)
	rec.tailHinge = motorHinge(
		"TailRotorHinge",
		rp.fin,
		CFrame.new(rp.thubLocal.X - rp.finLocal.X, rp.thubLocal.Y - rp.finLocal.Y, 0),
		rp.thub,
		CFrame.new(),
		40
	)
	table.insert(rec.physParts, rp.hub)
	table.insert(rec.physParts, rp.thub)
	table.insert(rec.physParts, body)

	-- flight constraints
	local root = newAttachment(body, "RootAttachment", CFrame.new())
	local lv = Instance.new("LinearVelocity")
	lv.Name = "FlightVelocity"
	lv.Attachment0 = root
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VectorVelocity = Vector3.zero
	-- body mass 270 (+ allowance 250 for seated characters) * g * 2.5 safety = ~255k  (> 270*196.2*1.5 = 79k)
	lv.MaxForce = (body.Mass + 250) * Workspace.Gravity * 2.5
	lv.Enabled = false
	lv.Parent = body
	local ao = Instance.new("AlignOrientation")
	ao.Name = "FlightOrient"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = root
	ao.RigidityEnabled = false
	ao.MaxTorque = 1e6
	ao.MaxAngularVelocity = 8
	ao.Responsiveness = 25
	ao.CFrame = uprightCFrame(body)
	ao.Enabled = false
	ao.Parent = body
	rec.lv, rec.ao = lv, ao
	rec.landing = false
	rec.landCheckT = 0
	rec.heliCfg = cfg
end

-- ---------------------------------------------------------------- lifecycle
local function assignOwner(rec)
	if rec.destroyed then
		return
	end
	local hum = rec.driverSeat.Occupant
	local plr = playerFromHumanoid(hum)
	if plr and not (plr.UserId == rec.ownerUserId or (plr.Team and plr.Team.Name == rec.teamName)) then
		plr = nil
	end
	for _, part in rec.physParts do
		if part.Parent then
			pcall(function()
				part:SetNetworkOwner(plr)
			end)
		end
	end
end

local function cleanupRecord(rec)
	if rec.destroyed then
		return
	end
	rec.destroyed = true
	records[rec.model] = nil
	if ownerVehicle[rec.ownerUserId] == rec.model then
		ownerVehicle[rec.ownerUserId] = nil
	end
	maidClean(rec.maid)
end

local function destroyVehicle(rec)
	cleanupRecord(rec)
	if rec.model.Parent then
		rec.model:Destroy()
	end
end

local function isOccupied(rec): boolean
	for _, seat in rec.seats do
		if seat.Occupant then
			return true
		end
	end
	return false
end

local function updateOccupancy(rec)
	local occupied = isOccupied(rec)
	if occupied then
		rec.lastOccupied = os.clock()
	end
	if rec.kind == "Helicopter" then
		rec.mainHinge.AngularVelocity = occupied and ROTOR_SPEED or 0
		rec.tailHinge.AngularVelocity = occupied and TAIL_ROTOR_SPEED or 0
	end
end

local function canRide(rec, hum): boolean
	local plr = playerFromHumanoid(hum)
	if not plr then
		return false
	end
	if plr.UserId == rec.ownerUserId then
		return true
	end
	return plr.Team ~= nil and plr.Team.Name == rec.teamName
end

local function eject(rec, seat, hum)
	local plr = playerFromHumanoid(hum)
	seat.Disabled = true
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	hum.Sit = false
	hum.Jump = true
	if plr then
		pcall(function()
			Remotes.event("Notify"):FireClient(plr, "That vehicle belongs to another team.", "error")
		end)
	end
	task.delay(1.5, function()
		if seat.Parent and not rec.destroyed then
			seat.Disabled = false
		end
	end)
end

local function beginLanding(rec)
	rec.landing = true
	rec.ao.CFrame = uprightCFrame(rec.primary)
	rec.ao.Enabled = true
	rec.lv.VectorVelocity = Vector3.new(0, -HELI_LAND_SPEED, 0)
	rec.lv.Enabled = true
end

local function onDriverChanged(rec)
	if rec.kind == "Helicopter" then
		local hum = rec.driverSeat.Occupant
		if hum then
			rec.landing = false
			rec.lv.VectorVelocity = Vector3.zero
			rec.ao.CFrame = uprightCFrame(rec.primary)
			rec.lv.Enabled = true
			rec.ao.Enabled = true
		else
			beginLanding(rec)
		end
	end
	assignOwner(rec)
end

local function onSeatChanged(rec, seat)
	if rec.destroyed then
		return
	end
	local hum = seat.Occupant
	if hum and not canRide(rec, hum) then
		eject(rec, seat, hum)
		return
	end
	updateOccupancy(rec)
	if seat == rec.driverSeat then
		onDriverChanged(rec)
	end
end

local function applyDamageFx(rec)
	if rec.fxOn or not rec.fxParent then
		return
	end
	rec.fxOn = true
	local smoke = Instance.new("Smoke")
	smoke.Name = "DamageSmoke"
	smoke.Color = Color3.fromRGB(40, 40, 40)
	smoke.Size = 8
	smoke.RiseVelocity = 8
	smoke.Opacity = 0.6
	smoke.Parent = rec.fxParent
	local fire = Instance.new("Fire")
	fire.Name = "DamageFire"
	fire.Size = 6
	fire.Heat = 8
	fire.Parent = rec.fxParent
end

local function explode(rec, attacker: Player?)
	rec.dead = true
	local pos = rec.primary.Position
	local ex = Instance.new("Explosion")
	ex.Position = pos
	ex.BlastRadius = 14
	ex.BlastPressure = 20000
	ex.DestroyJointRadiusPercent = 0
	ex.ExplosionType = Enum.ExplosionType.NoCraters
	ex.Parent = Workspace
	for _, seat in rec.seats do
		local hum = seat.Occupant
		if hum then
			pcall(function()
				callService(require(script.Parent.CombatService), "DamageHumanoid", attacker, hum, 100)
			end)
		end
	end
	task.delay(0.3, function()
		destroyVehicle(rec)
	end)
end

-- ---------------------------------------------------------------- per-frame logic
local function rightCar(rec)
	local chassis = rec.primary
	local pos = chassis.Position + Vector3.new(0, 5, 0)
	local look = chassis.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.2 then
		local up = chassis.CFrame.UpVector
		flat = Vector3.new(up.X, 0, up.Z)
	end
	if flat.Magnitude < 0.05 then
		flat = Vector3.new(0, 0, -1)
	end
	for _, part in rec.physParts do
		pcall(function()
			part:SetNetworkOwner(nil)
		end)
	end
	rec.model:PivotTo(CFrame.lookAt(pos, pos + flat.Unit))
	for _, part in rec.physParts do
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end
	task.delay(0.25, function()
		if not rec.destroyed then
			assignOwner(rec)
		end
	end)
end

local function updateCar(rec, dt: number)
	local cfg = Config.Vehicles.Car
	local seat = rec.driverSeat
	local chassis = rec.primary
	local tT, sT = 0, 0
	if seat.Occupant and canRide(rec, seat.Occupant) then
		tT = seat.ThrottleFloat
		sT = seat.SteerFloat
	end
	rec.throttle = approach(rec.throttle, tT, dt * 3)
	rec.steer = approach(rec.steer, sT, dt * 5)

	local fwdSpeed = chassis.AssemblyLinearVelocity:Dot(chassis.CFrame.LookVector)
	local maxSpeed = cfg.MaxSpeed

	-- drive
	local th = rec.throttle
	local omega = th * (maxSpeed / WHEEL_RADIUS)
	if th < 0 then
		omega *= 0.45
	end
	local torque = math.abs(tT) < 0.05 and cfg.Torque * 0.3 or cfg.Torque
	for _, motor in rec.motors do
		motor.AngularVelocity = DRIVE_SIGN * omega
		motor.MotorMaxTorque = torque
	end

	-- steer (less lock at speed)
	local lock = rec.steerAngle * (1 - 0.6 * math.min(1, math.abs(fwdSpeed) / maxSpeed))
	local target = math.deg(-rec.steer * lock * STEER_SIGN)
	for _, servo in rec.servos do
		servo.TargetAngle = target
	end

	-- sign self-calibration (only trips if the hinge convention is opposite to what we assumed)
	if not DRIVE_LOCKED and fwdSpeed * th > 15 then
		DRIVE_LOCKED = true
	end
	if not DRIVE_LOCKED and math.abs(th) > 0.6 and math.abs(tT) > 0.6 then
		if fwdSpeed * th < -4 then
			rec.calDrive += dt
			if rec.calDrive > 0.6 then
				DRIVE_SIGN = -DRIVE_SIGN
				rec.calDrive = 0
			end
		else
			rec.calDrive = 0
		end
	else
		rec.calDrive = 0
	end
	if not STEER_LOCKED and math.abs(fwdSpeed) > 8 and math.abs(rec.steer) > 0.6 then
		local yawRate = chassis.AssemblyAngularVelocity.Y
		local expected = -math.sign(rec.steer) * math.sign(fwdSpeed)
		if yawRate * expected > 0.3 then
			STEER_LOCKED = true
		elseif yawRate * expected < -0.2 then
			rec.calSteer += dt
			if rec.calSteer > 0.6 then
				STEER_SIGN = -STEER_SIGN
				rec.calSteer = 0
			end
		else
			rec.calSteer = 0
		end
	else
		rec.calSteer = 0
	end

	-- flip recovery
	if chassis.CFrame.UpVector.Y < 0.25 and chassis.AssemblyLinearVelocity.Magnitude < 6 then
		rec.flipT += dt
		if rec.flipT >= FLIP_TIME then
			rec.flipT = 0
			rightCar(rec)
		end
	else
		rec.flipT = 0
	end
end

local function updateHeliLanding(rec, dt: number)
	rec.landCheckT += dt
	if rec.landCheckT < 0.1 then
		return
	end
	rec.landCheckT = 0
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rec.model }
	local result = Workspace:Raycast(rec.primary.Position, Vector3.new(0, -12, 0), params)
	if result and result.Distance <= HELI_REST_HEIGHT then
		rec.landing = false
		rec.lv.VectorVelocity = Vector3.zero
		rec.lv.Enabled = false
		rec.ao.Enabled = false
	end
end

local function onHeartbeat(dt: number)
	for model, rec in records do
		if rec.destroyed or not model.Parent then
			continue
		end
		if rec.primary.Position.Y < KILL_Y then
			destroyVehicle(rec)
			continue
		end
		if rec.kind == "Car" then
			updateCar(rec, dt)
		elseif rec.landing then
			updateHeliLanding(rec, dt)
		end
	end
end

-- ---------------------------------------------------------------- spawn
local function removeOwnerVehicle(userId: number)
	local model = ownerVehicle[userId]
	if model then
		local rec = records[model]
		if rec then
			destroyVehicle(rec)
		elseif model.Parent then
			model:Destroy()
		end
		ownerVehicle[userId] = nil
	end
end

function VehicleService.SpawnVehicle(...)
	local player, kind = stripSelf(...)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "Invalid player"
	end
	if kind ~= "Car" and kind ~= "Helicopter" then
		return false, "Unknown vehicle"
	end
	if not vehiclesFolder then
		return false, "Vehicles unavailable"
	end
	local teamName, teamColor = teamInfo(player)
	local pad = findPad(teamName, kind)
	if not pad then
		return false, "No vehicle pad for your team"
	end

	removeOwnerVehicle(player.UserId)
	local spawnCF = computeSpawnCFrame(pad)

	local model = Instance.new("Model")
	model.Name = string.format("%s_%s", player.Name, kind)
	local rec = {
		model = model,
		kind = kind,
		ownerUserId = player.UserId,
		teamName = teamName,
		maid = newMaid(),
		parts = {},
		physParts = {},
		seats = {},
		pendingWelds = {},
		pendingHinges = {},
		lastOccupied = os.clock(),
		destroyed = false,
		dead = false,
	}

	local ok, err = pcall(function()
		if kind == "Car" then
			buildCar(rec, teamColor)
		else
			buildHelicopter(rec, teamColor)
		end
		model.Parent = vehiclesFolder
		model:PivotTo(spawnCF)
		for _, pair in rec.pendingWelds do
			local w = Instance.new("WeldConstraint")
			w.Part0 = pair[1]
			w.Part1 = pair[2]
			w.Parent = pair[1]
		end
		if kind == "Car" then
			assembleCar(rec)
		else
			assembleHelicopter(rec)
		end
	end)
	if not ok then
		warn("[VehicleService] build failed: " .. tostring(err))
		model:Destroy()
		return false, "Vehicle build failed"
	end

	model:SetAttribute("VehicleKind", kind)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("Team", teamName)
	model:SetAttribute("MaxHealth", Config.Vehicles.MaxHealth)
	model:SetAttribute("Health", Config.Vehicles.MaxHealth)

	records[model] = rec
	ownerVehicle[player.UserId] = model

	for _, seat in rec.seats do
		maidGive(rec.maid, seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			onSeatChanged(rec, seat)
		end))
	end
	maidGive(rec.maid, model.Destroying:Connect(function()
		cleanupRecord(rec)
	end))

	for _, part in rec.parts do
		part.Anchored = false
	end

	-- Put the buyer straight into the driver's seat so they don't have to jump on.
	task.defer(function()
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 and not hum.SeatPart and rec.driverSeat and not rec.destroyed then
			pcall(function()
				rec.driverSeat:Sit(hum)
			end)
		end
	end)
	return true, kind .. " delivered"
end

function VehicleService.GetVehicleFromPart(...)
	local part = stripSelf(...)
	local cur = part
	while cur and cur ~= Workspace do
		if cur:IsA("Model") and cur.Parent == vehiclesFolder then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

function VehicleService.DamageVehicle(...)
	local model, amount, attacker = stripSelf(...)
	if typeof(model) ~= "Instance" then
		return
	end
	local resolved = records[model] and model or VehicleService.GetVehicleFromPart(model)
	local rec = resolved and records[resolved]
	if not rec or rec.dead or rec.destroyed or type(amount) ~= "number" or amount <= 0 then
		return
	end
	local health = math.max(0, (rec.model:GetAttribute("Health") or 0) - amount)
	rec.model:SetAttribute("Health", health)
	if health <= Config.Vehicles.MaxHealth * 0.3 then
		applyDamageFx(rec)
	end
	if health <= 0 then
		explode(rec, attacker)
	end
end

function VehicleService.DespawnAll()
	local list = {}
	for _, rec in records do
		table.insert(list, rec)
	end
	for _, rec in list do
		destroyVehicle(rec)
	end
	table.clear(ownerVehicle)
	if vehiclesFolder then
		vehiclesFolder:ClearAllChildren()
	end
end

-- ---------------------------------------------------------------- service entry points
function VehicleService.Init(_self)
	local folder = Workspace:FindFirstChild("Vehicles")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Vehicles"
		folder.Parent = Workspace
	end
	vehiclesFolder = folder
	Players.PlayerRemoving:Connect(function(player)
		removeOwnerVehicle(player.UserId)
	end)
end

function VehicleService.Start(_self)
	RunService.Heartbeat:Connect(onHeartbeat)
	while true do
		task.wait(1)
		local now = os.clock()
		local idle = Config.Vehicles.IdleDespawn
		for _, rec in records do
			if not rec.destroyed then
				if isOccupied(rec) then
					rec.lastOccupied = now
				elseif now - rec.lastOccupied >= idle then
					destroyVehicle(rec)
				end
			end
		end
	end
end

return VehicleService
