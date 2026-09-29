# King of the Hill: Yellow vs Red vs Blue

Three teams fight over a central Combat Zone. Every 20 seconds, the team with the most people in the zone scores a point. A player standing in the moving **Hotzone** counts double, and the first team to 20 points wins. Each base has a gear vendor (assault rifle and armor) and a vehicle vendor (car and helicopter).

## Open it in Roblox Studio

**Option A: the place file (quickest)**
1. Download `build/KingOfTheHill.rbxlx`.
2. In Studio, open it with **File → Open from File…**.
3. Playtest with **Test → Clients and Servers**. Set players to 3 and press **Start**.
4. To publish it, use **File → Publish to Roblox As…**.

**Option B: Rojo (to keep editing from this repo)**
1. Install [Rojo](https://rojo.space) 7.x and the Rojo Studio plugin.
2. Run `rojo serve` inside `king-of-the-hill/`.
3. In Studio, open a Baseplate and click **Connect** in the Rojo plugin. Then delete the default `Baseplate` and `SpawnLocation` from Workspace.

To rebuild the place file yourself, run `rojo build default.project.json -o build/KingOfTheHill.rbxlx`.

## How to play
| Action | Keys |
|---|---|
| Shop | Walk up to a vendor stall in your base and press **E** |
| Fire / reload | Hold **Left Mouse** / **R** (gamepad **R2** / **X**, with on-screen buttons on mobile) |
| Car | **WASD** |
| Helicopter | **W/S** forward/back, **A/D** turn, **Space** up, **Ctrl/Q** down, **F** exit |

You're automatically seated in a vehicle when you buy it. Your teammates can ride along. Enemies can't get in.

## Rules and economy
- You start with **$300**.
- Every living player in the Combat Zone earns **$40** at each score tick, and each kill earns **$100**.
- Anything you earn while standing in the Hotzone pays **+50%**.
- Prices: rifle $250, armor $150, car $200, helicopter $500.
- When you die, you lose your rifle and armor.
- **Cash carries over** between matches. After a win, a 15 s intermission runs, then scores reset and everyone respawns at base.
- There is no friendly fire. You get a 5 s spawn shield.

Every number above is in `src/shared/Config.lua`.

## Project layout
```
default.project.json         Rojo mapping
src/shared/Config.lua        all tunables
src/shared/Remotes.lua       RemoteEvents/Functions
src/server/Services/         Team, Economy, Zone, Match, Combat, Vendor, Vehicle
src/client/Controllers/      Hud, Shop, Weapon, Vehicle
tools/build_map.py           generates src/workspace/Map.model.json (run it after editing)
build/KingOfTheHill.rbxlx    prebuilt place file
```
`PLAN.md` holds the design decisions, and `CONTRACTS.md` defines how the modules talk to each other.

## Status and known risks
This was built without access to a Roblox runtime. It passes a syntax check and a clean Rojo build, but it has not been playtested yet. Things to check first:
- **Car:** the drive and steer directions calibrate themselves on the first drive. You may see a brief moment of driving the wrong way the first time.
- **Helicopter:** it may need its handling numbers tuned in `Config.Vehicles.Helicopter` and `VehicleService.lua`.
- **Ramps:** a ramp may face the wrong way. If so, flip it in `tools/build_map.py`.
