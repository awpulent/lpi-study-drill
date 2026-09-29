-- Server entry point. Each service is a ModuleScript returning a table with :Init() and optionally :Start().
-- Init runs for all services first (wiring only, no yielding), then Start runs for all services.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

require(ReplicatedStorage.Shared.Remotes) -- creates remotes before any client asks

local Services = script.Parent:WaitForChild("Services")
local ORDER = {
	"TeamService",
	"EconomyService",
	"ZoneService",
	"CombatService",
	"VendorService",
	"VehicleService",
	"MatchService",
}

local loaded = {}
for _, name in ORDER do
	loaded[name] = require(Services:WaitForChild(name))
end
for _, name in ORDER do
	if loaded[name].Init then
		loaded[name]:Init()
	end
end
for _, name in ORDER do
	if loaded[name].Start then
		task.spawn(function()
			loaded[name]:Start()
		end)
	end
end
