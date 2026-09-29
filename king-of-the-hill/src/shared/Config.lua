--!strict
-- All gameplay tunables live here. Server and client both read this module.

local Config = {}

Config.Teams = {
	{ Name = "Yellow", BrickColor = BrickColor.new("Bright yellow"), Color = Color3.fromRGB(245, 205, 48) },
	{ Name = "Red", BrickColor = BrickColor.new("Bright red"), Color = Color3.fromRGB(196, 40, 28) },
	{ Name = "Blue", BrickColor = BrickColor.new("Bright blue"), Color = Color3.fromRGB(13, 105, 172) },
}

Config.Match = {
	TickInterval = 20, -- seconds between score ticks
	PointsToWin = 20,
	IntermissionTime = 15,
	HotzoneWeight = 2, -- a player in the hotzone counts as this many people
	SpawnProtection = 5, -- seconds of ForceField after spawning
	RespawnTime = 5,
}

Config.Zones = {
	Center = Vector3.new(0, 0, 0), -- ground-level center of the combat zone
	CombatRadius = 110,
	CombatHeight = 60, -- max height above ground that still counts as "in zone"
	HotzoneRadius = 18,
	HotzoneSpeed = 10, -- studs per second while gliding
	HotzonePause = 4, -- seconds it rests at each waypoint
}

Config.Economy = {
	StartingCash = 300,
	ZoneTickPay = 40, -- paid to each living player in the CZ at every score tick
	KillPay = 100,
	HotzoneMultiplier = 1.5, -- applied to any payout earned while in the hotzone
	PassiveIncome = 0,
}

Config.Shop = {
	-- Id = { Name, Price, Vendor }
	AssaultRifle = { Name = "Assault Rifle", Price = 250, Vendor = "Gear" },
	Armor = { Name = "Armor", Price = 150, Vendor = "Gear" },
	Car = { Name = "Car", Price = 200, Vendor = "Vehicle" },
	Helicopter = { Name = "Helicopter", Price = 500, Vendor = "Vehicle" },
}
Config.ShopOrder = {
	Gear = { "AssaultRifle", "Armor" },
	Vehicle = { "Car", "Helicopter" },
}
Config.VendorInteractDistance = 14

Config.Rifle = {
	ToolName = "AssaultRifle",
	Damage = 18,
	HeadshotMultiplier = 2,
	FireRate = 10, -- rounds per second
	MagazineSize = 30,
	ReloadTime = 2,
	Range = 600,
	Spread = 0.012, -- radians, max random deviation
	VehicleDamage = 12,
}

Config.Armor = {
	Max = 100,
}

Config.Vehicles = {
	MaxHealth = 600,
	IdleDespawn = 60, -- seconds with no driver before despawn
	Car = {
		MaxSpeed = 80,
		Torque = 20000,
		TurnSpeed = 1.2,
	},
	Helicopter = {
		MaxSpeed = 90,
		ClimbSpeed = 35,
		YawSpeed = 1.6, -- rad/s
		MaxTilt = math.rad(20),
	},
}

return Config
