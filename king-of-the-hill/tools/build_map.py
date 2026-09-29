#!/usr/bin/env python3
"""Generates src/workspace/Map.model.json (Rojo 7 model JSON) for the KotH map.

Run from anywhere:  python3 tools/build_map.py
Conventions: Y=0 is ground top, center (0,0,0), Roblox CFrame (LookVector = -Z column).
Bases sit at radius 420, angles 90/210/330 deg (x=R*cos, z=R*sin) and face the center.
"""
import json
import math
import os
import random

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "workspace", "Map.model.json")

BASE_RADIUS = 420
CZ_RADIUS = 110
TEAMS = [  # name, angle deg, brickcolor number, color
    ("Yellow", 90, 24, (245, 205, 48)),
    ("Red", 210, 21, (196, 40, 28)),
    ("Blue", 330, 23, (13, 105, 172)),
]


def c3(rgb):
    return [round(v / 255.0, 4) for v in rgb]


# ---------------------------------------------------------------- math
def mmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def rot_y(t):
    c, s = math.cos(t), math.sin(t)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def rot_z(t):
    c, s = math.cos(t), math.sin(t)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def rot_x(t):
    c, s = math.cos(t), math.sin(t)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


I3 = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]


class Frame:
    def __init__(self, pos=(0, 0, 0), rot=I3):
        self.pos = tuple(pos)
        self.rot = rot

    def apply(self, p):
        r = self.rot
        return tuple(self.pos[i] + sum(r[i][k] * p[k] for k in range(3)) for i in range(3))

    def __mul__(self, o):
        return Frame(self.apply(o.pos), mmul(self.rot, o.rot))


def yaw_facing(dx, dz):
    """Yaw angle so that the LookVector (-Z column) points along (dx, dz)."""
    return math.atan2(-dx, -dz)


def rnd(v):
    v = round(v, 5)
    return 0.0 if v == 0 else v


def cframe(fr):
    # Rojo 7.7 model JSON: flat 12-array [x,y,z, r00,r01,r02, r10,r11,r12, r20,r21,r22]
    return [rnd(v) for v in fr.pos] + [rnd(v) for row in fr.rot for v in row]


# ---------------------------------------------------------------- instances
_ids = [0]


def new_id(prefix="ref"):
    _ids[0] += 1
    return "%s_%d" % (prefix, _ids[0])


def inst(cls, name, props=None, attrs=None, children=None, ref_id=None):
    d = {"name": name, "className": cls, "properties": props or {}}
    if attrs:
        d["attributes"] = attrs
    if children:
        d["children"] = children
    if ref_id:
        d["id"] = ref_id
    return d


def part(name, size, local_pos, color, material="Concrete", frame=None, rot=I3, cls="Part",
         shape=None, transparency=None, collide=True, **extra):
    """Anchored part placed at local_pos within `frame` (world if None)."""
    frame = frame or Frame()
    world = frame * Frame(local_pos, rot)
    props = {
        "Size": [rnd(v) for v in size],
        "CFrame": cframe(world),
        "Color": c3(color) if isinstance(color[0], int) else list(color),
        "Material": material,
        "Anchored": True,
        "TopSurface": "Smooth",
        "BottomSurface": "Smooth",
    }
    if shape:
        props["Shape"] = shape
    if transparency is not None:
        props["Transparency"] = transparency
    if not collide:
        props["CanCollide"] = False
    props.update(extra)
    return inst(cls, name, props)


def disc(name, radius, thickness, world_pos, color, material="Concrete", frame=None, **kw):
    """Flat cylinder disc (cylinder axis is X, so rotate 90 deg about Z)."""
    return part(name, (thickness, radius * 2, radius * 2), world_pos, color, material,
                frame=frame, rot=rot_z(math.pi / 2), shape="Cylinder", **kw)


def sign_gui(text, face="Front"):
    label = inst("TextLabel", "Label", {
        "Size": {"UDim2": [[1, 0], [1, 0]]},
        "BackgroundTransparency": 1,
        "Text": text,
        "TextScaled": True,
        "TextColor3": [1, 1, 1],
        "TextStrokeTransparency": 0.3,
        "Font": "GothamBlack",
    })
    return inst("SurfaceGui", "SignGui", {"Face": face, "SizingMode": "PixelsPerStud",
                                          "PixelsPerStud": 40}, children=[label])


# ---------------------------------------------------------------- palette
GRAY = (110, 110, 115)
DARK = (60, 60, 64)
ASPHALT = (48, 48, 52)
SAND = (196, 178, 128)
WOOD = (139, 100, 60)
CONCRETE = (150, 150, 150)
WHITE = (240, 240, 240)
GROUND_GREEN = (86, 140, 62)


# ---------------------------------------------------------------- vendor
def make_vendor(kind, team, color, fr):
    """fr = frame of the stall (local -Z faces the player/center)."""
    label = "GEAR" if kind == "Gear" else "VEHICLES"
    name = "GearVendor" if kind == "Gear" else "VehicleVendor"
    cid = new_id("counter")
    dark = tuple(int(v * 0.55) for v in color)
    counter = part("Counter", (12, 3.6, 3), (0, 1.8, 0), WOOD, "Wood", fr)
    counter["id"] = cid
    kids = [
        counter,
        part("Floor", (16, 0.3, 12), (0, 0.15, 1), (90, 90, 95), "Concrete", fr),
        part("BackWall", (14, 9, 1), (0, 4.5, 5), GRAY, "Brick", fr),
        part("PostL", (1, 9, 1), (-6.5, 4.5, -3.5), dark, "Metal", fr),
        part("PostR", (1, 9, 1), (6.5, 4.5, -3.5), dark, "Metal", fr),
        part("Roof", (16, 0.8, 12), (0, 9.4, 0.5), color, "SmoothPlastic", fr),
    ]
    sign = part("Sign", (12, 3.4, 0.6), (0, 11.5, -0.5), color, "SmoothPlastic", fr)
    sign["children"] = [sign_gui(label)]
    kids.append(sign)
    return inst("Model", name, {"PrimaryPart": {"Ref": cid}},
                {"VendorType": kind, "Team": team}, kids)


# ---------------------------------------------------------------- base
def make_base(team, angle_deg, bcn, color):
    a = math.radians(angle_deg)
    cx, cz = BASE_RADIUS * math.cos(a), BASE_RADIUS * math.sin(a)
    yaw = yaw_facing(-cx, -cz)
    fr = Frame((cx, 0, cz), rot_y(yaw))  # local -Z points at map center
    dark = tuple(int(v * 0.6) for v in color)
    light = tuple(min(255, int(v * 0.4 + 150)) for v in color)
    kids = []

    # floor slab (top at 0.4) and team-colored inner marking
    kids.append(part("Floor", (150, 0.4, 140), (0, 0.2, 0), (95, 95, 100), "Concrete", fr))
    kids.append(part("FloorStripe", (150, 0.1, 6), (0, 0.45, 8), color, "SmoothPlastic", fr, collide=False))

    # walls (8 high, 2 thick); front wall (z=-70) has a 60-wide opening in the middle
    H, T = 8, 2
    kids.append(part("WallBack", (154, H, T), (0, H / 2, 71), color, "Concrete", fr))
    kids.append(part("WallLeft", (T, H, 140), (-76, H / 2, 0), color, "Concrete", fr))
    kids.append(part("WallRight", (T, H, 140), (76, H / 2, 0), color, "Concrete", fr))
    kids.append(part("WallFrontLeft", (46, H, T), (-53, H / 2, -71), color, "Concrete", fr))
    kids.append(part("WallFrontRight", (46, H, T), (53, H / 2, -71), color, "Concrete", fr))
    # gate posts and trim
    for sx in (-1, 1):
        kids.append(part("GatePost", (5, 14, 5), (sx * 31, 7, -71), dark, "Concrete", fr))
        kids.append(part("GateBeacon", (3, 3, 3), (sx * 31, 15.5, -71), color, "Neon", fr))
    for sx in (-1, 1):  # low wall caps
        kids.append(part("Cap", (T + 1, 1, 46 if False else 3), (sx * 76, H + 0.5, -68), dark, "Concrete", fr))

    # spawns: 4 SpawnLocations at the back
    bid = "brickcolor_" + team
    for i, sx in enumerate((-30, -10, 10, 30)):
        world = fr * Frame((sx, 1.0, 45), I3)
        kids.append(inst("SpawnLocation", "Spawn", {
            "Size": [8, 1, 8],
            "CFrame": cframe(world),
            "Color": c3(color),
            "Material": "Neon",
            "Anchored": True,
            "CanCollide": True,
            "TopSurface": "Smooth",
            "BottomSurface": "Smooth",
            "TeamColor": {"BrickColor": bcn},
            "Neutral": False,
            "Duration": 5,
            "AllowTeamChangeOnTouch": False,
            "Transparency": 0.35,
        }, {"Team": team}))

    # vendor stalls facing center; gear on left(-x), vehicles on right(+x)
    kids.append(make_vendor("Gear", team, color, fr * Frame((-45, 0.4, 0))))
    kids.append(make_vendor("Vehicle", team, color, fr * Frame((45, 0.4, 0))))

    # pads
    padrot = I3
    car = part("CarPad", (18, 0.6, 26), (10, 0.7, -35), (70, 70, 74), "Concrete", fr, rot=padrot)
    heli = part("HeliPad", (30, 0.6, 30), (52, 0.7, -35), (70, 70, 74), "Concrete", fr, rot=padrot)
    pads = inst("Folder", "VehiclePads", {}, None, [car, heli])
    kids.append(pads)
    # pad markings (non-colliding, on top: pad top = 1.0)
    kids.append(part("CarPadStripeL", (0.8, 0.1, 24), (10 - 7, 1.05, -35), color, "SmoothPlastic", fr, collide=False))
    kids.append(part("CarPadStripeR", (0.8, 0.1, 24), (10 + 7, 1.05, -35), color, "SmoothPlastic", fr, collide=False))
    kids.append(part("CarPadArrow", (6, 0.1, 3), (10, 1.05, -42), WHITE, "SmoothPlastic", fr, collide=False))
    kids.append(disc("HeliPadRing", 13, 0.1, (52, 1.05, -35), color, "SmoothPlastic", fr, collide=False))
    kids.append(disc("HeliPadInner", 10.5, 0.1, (52, 1.1, -35), (70, 70, 74), "Concrete", fr, collide=False))
    kids.append(part("HeliH1", (2, 0.1, 10), (52 - 3.5, 1.15, -35), WHITE, "SmoothPlastic", fr, collide=False))
    kids.append(part("HeliH2", (2, 0.1, 10), (52 + 3.5, 1.15, -35), WHITE, "SmoothPlastic", fr, collide=False))
    kids.append(part("HeliHBar", (5, 0.1, 2), (52, 1.15, -35), WHITE, "SmoothPlastic", fr, collide=False))

    # banner pole with team flag near the gate for visibility
    kids.append(part("FlagPole", (1, 40, 1), (-45, 20, 55), GRAY, "Metal", fr))
    kids.append(part("Flag", (0.4, 8, 14), (-45, 35, 62), color, "SmoothPlastic", fr))

    base = inst("Model", team, {}, {"Team": team}, kids)
    info = {
        "center": (cx, cz), "yaw": yaw, "frame": fr,
    }
    return base, info


# ---------------------------------------------------------------- map
def dist_to_road(x, z, road_dirs):
    best = 1e9
    for (dx, dz) in road_dirs:
        t = x * dx + z * dz
        if t < 0:
            d = math.hypot(x, z)
        else:
            d = abs(x * dz - z * dx)
        best = min(best, d)
    return best


def build():
    random.seed(1337)
    children = []

    # Ground
    children.append(part("Ground", (1300, 4, 1300), (0, -2, 0), GROUND_GREEN, "Grass"))
    children[-1]["properties"]["Anchored"] = True

    # Bases
    base_kids = []
    road_dirs = []
    infos = {}
    for team, ang, bcn, col in TEAMS:
        base, info = make_base(team, ang, bcn, col)
        base_kids.append(base)
        infos[team] = info
        a = math.radians(ang)
        road_dirs.append((math.cos(a), math.sin(a)))
    children.append(inst("Folder", "Bases", {}, None, base_kids))

    # Combat zone visual disc: radius 110, thin, just above the ground
    cz = disc("CombatZone", CZ_RADIUS, 0.2, (0, 0.3, 0), (255, 255, 255), "ForceField",
              transparency=0.8, collide=False)
    cz["properties"]["CanQuery"] = False
    cz["properties"]["CanTouch"] = False
    cz["properties"]["CastShadow"] = False
    cz["properties"]["Color"] = [1.0, 0.85, 0.35]
    children.append(cz)
    # bright ring around the CZ edge (thin non-colliding blocks approximating a ring)
    ring = []
    n = 72
    seg_len = 2 * math.pi * CZ_RADIUS / n + 0.6
    for i in range(n):
        t = 2 * math.pi * i / n
        px, pz = CZ_RADIUS * math.cos(t), CZ_RADIUS * math.sin(t)
        yaw = yaw_facing(-px, -pz)  # look toward center; segment length along local X
        ring.append(part("Seg", (seg_len, 0.15, 1.6), (px, 0.12, pz), (255, 210, 60), "Neon",
                         rot=rot_y(yaw), collide=False, CanQuery=False, CanTouch=False))
    decor = [inst("Folder", "CombatZoneRing", {}, None, ring)]

    # Roads from each base gate (r=349) into the CZ (to r=10)
    roads = []
    for team, ang, bcn, col in TEAMS:
        a = math.radians(ang)
        dx, dz = math.cos(a), math.sin(a)
        r0, r1 = 349, 12
        mid = (r0 + r1) / 2
        length = r0 - r1
        yaw = yaw_facing(-dx, -dz)
        roads.append(part("Road_" + team, (26, 0.2, length), (dx * mid, 0.1, dz * mid), ASPHALT,
                          "Asphalt", rot=rot_y(yaw)))
        # dashed center line
        k = 0
        r = r0 - 10
        while r > r1 + 10:
            roads.append(part("Dash", (1, 0.05, 8), (dx * r, 0.22, dz * r), (230, 200, 60),
                              "SmoothPlastic", rot=rot_y(yaw), collide=False))
            r -= 24
            k += 1
        # team colored pad at road start (apron in front of gate)
        roads.append(part("Apron_" + team, (60, 0.2, 14), (dx * 338, 0.12, dz * 338), col,
                          "SmoothPlastic", rot=rot_y(yaw), collide=False))
    children.append(inst("Folder", "Roads", {}, None, roads))

    # Helicopter landing marks in the CZ (kept clear of cover): between roads
    heli_spots = []
    for ang in (30, 150, 270):
        a = math.radians(ang)
        heli_spots.append((70 * math.cos(a), 70 * math.sin(a)))
    for i, (hx, hz) in enumerate(heli_spots):
        decor.append(disc("LandingMark%d" % (i + 1), 16, 0.1, (hx, 0.2, hz), (220, 220, 225),
                          "SmoothPlastic", collide=False))
        decor.append(disc("LandingMarkInner%d" % (i + 1), 13.5, 0.1, (hx, 0.25, hz), (90, 90, 96),
                          "Concrete", collide=False))
        decor.append(part("LandingH%d" % (i + 1), (2, 0.1, 9), (hx - 3, 0.3, hz), WHITE,
                          "SmoothPlastic", collide=False))
        decor.append(part("LandingH%db" % (i + 1), (2, 0.1, 9), (hx + 3, 0.3, hz), WHITE,
                          "SmoothPlastic", collide=False))
        decor.append(part("LandingH%dc" % (i + 1), (5, 0.1, 2), (hx, 0.3, hz), WHITE,
                          "SmoothPlastic", collide=False))
    children.append(inst("Folder", "Decor", {}, None, decor))

    # ---------------- cover
    cover = []
    placed = []  # (x, z, r) occupied circles

    def free(x, z, r, in_cz_only=False):
        if dist_to_road(x, z, road_dirs) < 26 + r:
            return False
        for (hx, hz) in heli_spots:
            if math.hypot(x - hx, z - hz) < 24 + r:
                return False
        if math.hypot(x, z) < 34 + r:  # around central structure
            return False
        for (px, pz, pr) in placed:
            if math.hypot(x - px, z - pz) < pr + r + 2:
                return False
        return True

    def take(x, z, r):
        placed.append((x, z, r))

    # central structure at (0,0): 26x26 compound, 4 doorways, raised roof platform with ramps
    cs = []
    S, h, t = 13, 9, 2
    door = 9
    for sgn in (-1, 1):
        # north/south walls (along X), doorway in middle
        seglen = S - door / 2
        for sx in (-1, 1):
            cs.append(part("CenterWall", (seglen, h, t), (sx * (door / 2 + seglen / 2), h / 2, sgn * S), CONCRETE, "Concrete"))
        # east/west walls (along Z)
        for sz in (-1, 1):
            cs.append(part("CenterWall", (t, h, seglen), (sgn * S, h / 2, sz * (door / 2 + seglen / 2)), CONCRETE, "Concrete"))
    cs.append(part("CenterPillar", (6, h, 6), (0, h / 2, 0), (120, 120, 125), "Concrete"))
    cs.append(part("CenterPlatform", (10, 1, 10), (0, h + 0.5, 0), (200, 170, 60), "Metal"))
    # corner posts
    for sx in (-1, 1):
        for sz in (-1, 1):
            cs.append(part("CenterCorner", (5, h + 3, 5), (sx * S, (h + 3) / 2, sz * S), (100, 100, 105), "Concrete"))
    cover.extend(cs)

    def crate(x, z, size=None, stack=False):
        s = size or random.choice([4, 5, 6, 7])
        yaw = random.uniform(0, math.pi)
        cover.append(part("Crate", (s, s, s), (x, s / 2, z), WOOD, "WoodPlanks", rot=rot_y(yaw)))
        take(x, z, s * 0.75)
        if stack:
            s2 = s * 0.7
            cover.append(part("Crate", (s2, s2, s2), (x + random.uniform(-0.5, 0.5), s + s2 / 2, z),
                              (150, 110, 70), "WoodPlanks", rot=rot_y(yaw + 0.4)))

    def wall(x, z, length, yaw, height=6):
        cover.append(part("CoverWall", (length, height, 2), (x, height / 2, z), CONCRETE, "Concrete", rot=rot_y(yaw)))
        take(x, z, length / 2)

    def ramp(x, z, yaw, w=12, hgt=6, ln=18):
        """WedgePart; high edge toward local +Z after yaw."""
        cover.append(part("Ramp", (w, hgt, ln), (x, hgt / 2, z), (170, 150, 110), "Concrete", rot=rot_y(yaw), cls="WedgePart"))
        take(x, z, ln / 2)

    def building(x, z, yaw, w=22, d=16, h=8):
        fr = Frame((x, 0, z), rot_y(yaw))
        t = 1.5
        dw = 7
        pieces = [
            ("BldgBack", (w, h, t), (0, h / 2, d / 2)),
            ("BldgLeft", (t, h, d), (-w / 2, h / 2, 0)),
            ("BldgRight", (t, h, d), (w / 2, h / 2, 0)),
            ("BldgFrontL", ((w - dw) / 2, h, t), (-(w + dw) / 4, h / 2, -d / 2)),
            ("BldgFrontR", ((w - dw) / 2, h, t), ((w + dw) / 4, h / 2, -d / 2)),
            ("BldgRoof", (w, 1, d), (0, h + 0.5, 0)),
        ]
        for n, sz, lp in pieces:
            cover.append(part(n, sz, lp, (135, 120, 105) if n != "BldgRoof" else (90, 80, 75),
                              "Brick" if n != "BldgRoof" else "Slate", fr))
        take(x, z, max(w, d) / 2 + 2)

    # deliberate features
    features = [
        ("building", 60, 25), ("building", -55, -40), ("building", -25, 70), ("building", 30, -75),
        ("ramp", -70, 20), ("ramp", 45, 55),
    ]
    for kind, fx, fz in features:
        if kind == "building":
            # turn to face center-ish
            if free(fx, fz, 14):
                building(fx, fz, yaw_facing(-fx, -fz))
        else:
            if free(fx, fz, 10):
                ramp(fx, fz, yaw_facing(-fx, -fz))
    # ramps flanking the central structure so the platform is reachable? (put ramp to bunker roof)
    cover.append(part("CenterRamp", (10, 9.5, 20), (0, 4.75, 26), (170, 150, 110), "Concrete",
                      rot=rot_y(math.pi), cls="WedgePart"))  # high edge toward -Z (center)

    # random crates, walls in CZ
    tries = 0
    count = {"crate": 0, "wall": 0}
    while (count["crate"] < 22 or count["wall"] < 12) and tries < 4000:
        tries += 1
        rr = math.sqrt(random.uniform(35 ** 2, 104 ** 2))
        th = random.uniform(0, 2 * math.pi)
        x, z = rr * math.cos(th), rr * math.sin(th)
        if count["crate"] < 22 and (random.random() < 0.6 or count["wall"] >= 12):
            if free(x, z, 5):
                crate(x, z, stack=random.random() < 0.3)
                count["crate"] += 1
        elif count["wall"] < 12:
            ln = random.choice([10, 14, 18])
            if free(x, z, ln / 2):
                wall(x, z, ln, random.choice([0, math.pi / 2, math.pi / 4, -math.pi / 4]) + random.uniform(-0.2, 0.2))
                count["wall"] += 1

    # a few pieces of outer cover between the CZ and the bases (r 120..300), off the roads
    outer = 0
    tries = 0
    while outer < 26 and tries < 3000:
        tries += 1
        rr = random.uniform(125, 320)
        th = random.uniform(0, 2 * math.pi)
        x, z = rr * math.cos(th), rr * math.sin(th)
        if dist_to_road(x, z, road_dirs) < 40:
            continue
        if any(math.hypot(x - px, z - pz) < pr + 8 for (px, pz, pr) in placed):
            continue
        if random.random() < 0.6:
            crate(x, z, stack=random.random() < 0.3)
        else:
            wall(x, z, random.choice([12, 16]), random.uniform(0, math.pi))
        outer += 1

    children.append(inst("Folder", "Cover", {}, None, cover))

    root = inst("Model", "Map", {}, None, children)
    return root


def main():
    root = build()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(root, f, indent=1)
    n = [0]

    def count(d):
        n[0] += 1
        for c in d.get("children", []):
            count(c)
    count(root)
    print("Wrote %s (%d instances)" % (os.path.normpath(OUT), n[0]))


if __name__ == "__main__":
    main()
