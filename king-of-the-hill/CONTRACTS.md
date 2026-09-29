# Module Contracts

Every module must follow these contracts. Services talk to each other only through the public functions listed here. `require` sibling services lazily (inside functions or in `Init`) to avoid ordering issues. `Main.server.lua` requires all of them before calling any `Init`.

Style: Luau, tabs, `--!strict` where practical. No Toolbox assets. Everything is built from Parts and constraints in code, or by the map generator.

## Shared
- `ReplicatedStorage.Shared.Config`: all tunables. Never hard-code numbers that already exist there.
- `ReplicatedStorage.Shared.Remotes`: `Remotes.event(name)` / `Remotes.func(name)`. The names and payloads are documented in that file. Do not add remotes without also adding them there.

## Replicated state
- `ReplicatedStorage.GameState` (Folder, created by MatchService) has these attributes:
  - `Phase`: `"Playing"` or `"Intermission"`
  - `Score_Yellow`, `Score_Red`, `Score_Blue`: number
  - `NextTickAt`: number, compared against `workspace:GetServerTimeNow()`
  - `IntermissionEndsAt`: number
  - `Winner`: team name, or `""`
  - `LastTickWinner`: team name, or `""`
- Player attributes:
  - `Cash`: number, owned by EconomyService, also mirrored to `leaderstats.Cash`
  - `Armor` and `MaxArmor`: numbers, owned by CombatService
  - `Zone`: `"None"`, `"Combat"` or `"Hot"`, owned by ZoneService. `"Hot"` means the player is also inside the CZ.
- `Workspace.Hotzone`: a Part (flat cylinder) created and moved by ZoneService.
- `Workspace.Vehicles`: a Folder created by VehicleService. Each vehicle Model has these attributes:
  - `VehicleKind`: `"Car"` or `"Helicopter"`
  - `OwnerUserId`: number
  - `Team`: string
  - `Health` and `MaxHealth`: numbers

## Map (`Workspace.Map`, produced by `tools/build_map.py` → `src/workspace/Map.model.json`)
- The ground's top surface is at **Y = 0**. The map center is (0, 0, 0).
- `Map.CombatZone`: an anchored, non-colliding, non-queryable, semi-transparent Cylinder disc at the center, with radius `Config.Zones.CombatRadius` (110). It is visual only, because the zone logic uses distance checks.
- `Map.Cover`: a Folder of anchored cover blocks and ramps inside and around the CZ.
- `Map.Bases.<Team>` for Yellow, Red and Blue: a Model each, placed at radius 420 from the center at angles 90°, 210° and 330°, facing the center. Each base contains:
  - Several `SpawnLocation`s named `Spawn`, with attribute `Team=<Team>`, `Neutral=false` and `Duration=5`. Their TeamColor is set by the generator and also re-applied at runtime by TeamService.
  - `GearVendor`: a Model with PrimaryPart `Counter` and attributes `VendorType="Gear"` and `Team=<Team>`.
  - `VehicleVendor`: a Model with PrimaryPart `Counter` and attributes `VendorType="Vehicle"` and `Team=<Team>`.
  - `VehiclePads`: a Folder with Parts `CarPad` and `HeliPad`, anchored. A vehicle spawns 4 studs above the pad's top surface, facing the pad's LookVector.

## Server services (`ServerScriptService.Server.Services.*`)
Each service is a table with `Init()` (no yields) and an optional `Start()`.

**TeamService**
- `Init`: creates the Teams from `Config.Teams` (AutoAssignable=false (TeamService balances manually)) and sets the SpawnLocation TeamColor from attributes.
- Balances assignment on PlayerAdded by putting the player on the smallest team.
- `GetTeamName(player): string?`
- `GetBase(teamName): Model`
- `RespawnAll()`: calls `LoadCharacter` for everyone.

**EconomyService**
- Creates leaderstats and the `Cash` attribute on join, set to StartingCash.
- Cash is never reset by match restarts. That is the carryover.
- `GetCash(player): number`
- `AddCash(player, amount, reason: string): number`
  - Applies `Config.Economy.HotzoneMultiplier` when `ZoneService.GetPlayerZone(player) == "Hot"`.
  - Rounds the result.
  - Fires `Notify` with kind `"cash"`, e.g. `"+$60 Kill (Hotzone bonus!)"`.
  - Returns the amount actually paid.
- `TrySpend(player, amount): boolean`

**ZoneService**
- Every 0.2 s it sets the `Zone` attribute on each player.
- A player counts only if their Humanoid is alive, their horizontal distance to the CZ center is within the radius, and their root height is within `CombatHeight` above ground. Players inside vehicles count.
- It glides `Workspace.Hotzone` between random waypoints inside the CZ, kept inside radius `CombatRadius - HotzoneRadius`.
- `GetPlayerZone(player): "None" | "Combat" | "Hot"`
- `ResetHotzone()`

**MatchService**
- Owns GameState and the match loop.
- Every `TickInterval` seconds while Playing:
  - Pays `ZoneTickPay` to each player in Combat or Hot via `EconomyService.AddCash`.
  - Computes team weights (Hot = `HotzoneWeight`, Combat = 1).
  - Awards 1 point to the unique top team if its weight is above 0.
  - Sets `LastTickWinner` and sends `Notify` "score" to all.
- At `PointsToWin`:
  - Sets `Winner`, switches Phase to Intermission and sets `IntermissionEndsAt`.
  - Calls `CombatService.ResetAll()`, `VehicleService.DespawnAll()` and `ZoneService.ResetHotzone()`.
  - After the intermission: resets scores, calls `TeamService.RespawnAll()` and goes back to Playing.
- `GetPhase(): string`

**CombatService**
- `GiveRifle(player): (boolean, string)` builds a Tool named `Config.Rifle.ToolName` in code, with a `Handle` and a child `Muzzle` Attachment. It fails if the player already has one.
- `GiveArmor(player): (boolean, string)` fails if armor is already full.
- Handles `FireWeapon(aimPoint)`:
  - Checks the rate limit, the ammo, that the tool is equipped, and that the player is alive.
  - Raycasts from the muzzle toward the aimPoint with spread, excluding the shooter's character.
  - Damages the Humanoid, or damages a vehicle via `VehicleService.DamageVehicle` when the hit belongs to `Workspace.Vehicles`.
  - Friendly fire is off.
  - Fires `WeaponFx` to all and `HitMarker` to the shooter.
- Handles `ReloadWeapon` and sends `AmmoUpdate`.
- `DamageHumanoid(attacker: Player?, humanoid, amount)`:
  - Armor absorbs damage first.
  - Tracks the last attacker. On death it pays `KillPay` via EconomyService and sends `Notify`.
- Armor is reset on CharacterAdded. The rifle is lost naturally on death.
- `ResetAll()`: strips rifles and armor from everyone.

**VendorService**
- Adds a ProximityPrompt to each vendor Counter (MaxActivationDistance = `Config.VendorInteractDistance`).
- When the prompt is triggered by a player on the same team, it fires `OpenShop:FireClient(player, vendorType)`.
- `Purchase(itemId)` validates:
  - that the item exists
  - that the phase is Playing
  - that the player is alive
  - that the player is within `VendorInteractDistance + 4` of a vendor of the right type on their own team
  - that the player can afford it, via `TrySpend`
- It then delivers via CombatService or VehicleService, and refunds if the delivery fails.

**VehicleService**
- `SpawnVehicle(player, kind): (boolean, string)`:
  - Builds a Car or Helicopter from Parts and constraints at the player's team pad.
  - Removes the player's previous vehicle.
  - Gives the driver network ownership when they sit, and gives it back to the server when they leave.
  - Despawns the vehicle after `IdleDespawn` seconds with no driver.
- `DamageVehicle(model, amount, attacker: Player?)` destroys the vehicle at 0 health with an Explosion. It damages the occupants through `CombatService.DamageHumanoid`, crediting the attacker.
- `GetVehicleFromPart(part): Model?`
- `DespawnAll()`

## Client controllers (`StarterPlayerScripts.Client.Controllers.*`)
- **HudController**: a ScreenGui (ResetOnSpawn=false) showing:
  - three team score bars (x/20) in team colors, with your team highlighted
  - the next-tick countdown
  - a zone status badge (None / In Combat Zone / In HOTZONE ×2)
  - cash
  - an armor bar
  - an ammo counter (from `AmmoUpdate`, visible only while the rifle is equipped)
  - a notification feed (`Notify`)
  - the winner banner and intermission countdown
- **ShopController**: on `OpenShop`, shows a panel with the vendor's items (`Config.ShopOrder`), prices, and a Buy button that calls `Purchase:InvokeServer`. It shows the result message and closes on the X button or when the player walks more than 20 studs away.
- **WeaponController**:
  - While the rifle is equipped: hold the mouse to fire automatically at `FireRate`, sending `FireWeapon(mouseHitPosition)`. The client does its own raycast from the camera through the mouse, ignoring its own character.
  - R reloads.
  - Shows a custom crosshair and the hitmarker, and draws short-lived tracer beams from `WeaponFx`.
  - Touch and gamepad support: fire with the ButtonR2 key, or with an on-screen button when TouchEnabled.
- **VehicleController**: when the local player sits in the VehicleSeat of a Helicopter (their own or a teammate's):
  - Any teammate may pilot, not only the owner.
  - It drives flight on the client, because the client is the network owner.
  - Controls: W/S move forward and back, A/D yaw, Space climbs, LeftCtrl or Q descends.
  - It uses the vehicle's LinearVelocity and AlignOrientation.
  - The car uses VehicleSeat throttle and steer. It is driven either server-side or client-side, as VehicleService documents, and whichever is chosen must be consistent.
