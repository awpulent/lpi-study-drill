-- Client entry point. Each controller is a ModuleScript returning a table with :Init() and optionally :Start().

local Controllers = script.Parent:WaitForChild("Controllers")
local ORDER = {
	"HudController",
	"ShopController",
	"WeaponController",
	"VehicleController",
}

local loaded = {}
for _, name in ORDER do
	loaded[name] = require(Controllers:WaitForChild(name))
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
