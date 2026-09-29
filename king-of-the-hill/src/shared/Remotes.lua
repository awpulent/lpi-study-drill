--!strict
-- Single source of truth for networking objects.
-- The server creates them on first require. The client waits for them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EVENTS = {
	"FireWeapon", -- C->S (aimPoint: Vector3) server raycasts from the rifle muzzle toward it
	"ReloadWeapon", -- C->S ()
	"WeaponFx", -- S->all (shooter: Player, origin: Vector3, hitPos: Vector3)
	"HitMarker", -- S->shooter (isHeadshot: boolean, isKill: boolean)
	"Notify", -- S->client (text: string, kind: "info"|"cash"|"error"|"score")
	"OpenShop", -- S->client (vendorType: "Gear"|"Vehicle")
	"AmmoUpdate", -- S->client (ammoInMag: number, isReloading: boolean)
}

local FUNCTIONS = {
	"Purchase", -- C->S (itemId: string) -> (ok: boolean, message: string)
}

local Remotes = {}

local folder: Folder
if RunService:IsServer() then
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing then
		folder = existing :: Folder
	else
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	for _, name in EVENTS do
		if not folder:FindFirstChild(name) then
			local e = Instance.new("RemoteEvent")
			e.Name = name
			e.Parent = folder
		end
	end
	for _, name in FUNCTIONS do
		if not folder:FindFirstChild(name) then
			local f = Instance.new("RemoteFunction")
			f.Name = name
			f.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

function Remotes.event(name: string): RemoteEvent
	return folder:WaitForChild(name) :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	return folder:WaitForChild(name) :: RemoteFunction
end

return Remotes
