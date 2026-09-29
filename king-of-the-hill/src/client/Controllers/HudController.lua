-- HudController: builds the whole HUD in code and keeps it in sync with GameState / player attributes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local HudController = {}

local player = Players.LocalPlayer

local FONT = Enum.Font.GothamBold
local FONT_HEAVY = Enum.Font.GothamBlack
local PANEL = Color3.fromRGB(20, 22, 28)
local GREY = Color3.fromRGB(120, 124, 132)
local WHITE = Color3.fromRGB(240, 240, 245)
local ORANGE = Color3.fromRGB(255, 140, 20)
local GREEN = Color3.fromRGB(90, 230, 120)
local KIND_COLORS = {
	info = Color3.fromRGB(235, 235, 240),
	cash = Color3.fromRGB(110, 235, 130),
	error = Color3.fromRGB(255, 100, 90),
	score = Color3.fromRGB(255, 205, 80),
}
local MAX_FEED = 5
local FEED_LIFETIME = 4

local teamConfig: { [string]: any } = {}
for _, t in Config.Teams do
	teamConfig[t.Name] = t
end

local connections: { RBXScriptConnection } = {}
local scales: { UIScale } = {}

-- UI refs
local gui: ScreenGui
local cards: { [string]: { frame: Frame, stroke: UIStroke, fill: Frame, score: TextLabel } } = {}
local timerLabel: TextLabel
local badge: Frame
local badgeStroke: UIStroke
local badgeLabel: TextLabel
local cashLabel: TextLabel
local armorFrame: Frame
local armorFill: Frame
local armorText: TextLabel
local ammoFrame: Frame
local ammoLabel: TextLabel
local feed: Frame
local banner: Frame
local bannerTitle: TextLabel
local bannerSub: TextLabel

local gameState: Folder
local ammo = Config.Rifle.MagazineSize
local reloading = false
local lastCash = 0
local feedItems: { { frame: Frame, dead: boolean } } = {}
local feedOrder = 0

local function connect(signal: RBXScriptSignal, fn: (...any) -> ())
	table.insert(connections, signal:Connect(fn))
end

local function tween(obj: Instance, time: number, props: { [string]: any })
	TweenService:Create(obj, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local function localTeamName(): string?
	local t = player.Team
	if t and teamConfig[t.Name] then
		return t.Name
	end
	return nil
end

local function localTeamColor(): Color3
	local n = localTeamName()
	return if n then teamConfig[n].Color else GREY
end

-- Builders ---------------------------------------------------------------

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local o = Instance.new(className)
	for k, v in props do
		(o :: any)[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function corner(parent: Instance, radius: number)
	return make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local p = {
		BackgroundTransparency = 1,
		Font = FONT,
		TextColor3 = WHITE,
		TextSize = 18,
		Text = "",
	}
	for k, v in props do
		p[k] = v
	end
	return make("TextLabel", p, parent)
end

-- A container that scales with the viewport (phone friendly).
local function section(name: string, anchor: Vector2, position: UDim2, size: UDim2): Frame
	local f = make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		AnchorPoint = anchor,
		Position = position,
		Size = size,
	}, gui)
	local s = make("UIScale", {}, f)
	table.insert(scales, s)
	return f
end

local function updateScale()
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local k = math.clamp(math.min(vp.X / 1100, vp.Y / 650), 0.55, 1.25)
	for _, s in scales do
		s.Scale = k
	end
end

local function buildGui()
	local playerGui = player:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("KothHud")
	if old then
		old:Destroy()
	end
	gui = make("ScreenGui", {
		Name = "KothHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 5,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)

	-- Top center: scores, timer, zone badge
	local top = section("Top", Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 44), UDim2.fromOffset(500, 150))
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, top)

	local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(500, 60), LayoutOrder = 1 }, top)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)

	for i, t in Config.Teams do
		local card = make("Frame", {
			Name = t.Name,
			Size = UDim2.fromOffset(156, 58),
			BackgroundColor3 = PANEL,
			BackgroundTransparency = 0.25,
			LayoutOrder = i,
		}, row)
		corner(card, 10)
		local st = stroke(card, t.Color, 1, 0.6)
		label(card, {
			Text = string.upper(t.Name),
			TextColor3 = t.Color,
			TextSize = 15,
			Font = FONT_HEAVY,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(10, 5),
			Size = UDim2.new(0.5, -10, 0, 20),
		})
		local score = label(card, {
			Text = "0 / " .. Config.Match.PointsToWin,
			TextSize = 17,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.new(0.4, 0, 0, 5),
			Size = UDim2.new(0.6, -10, 0, 20),
		})
		local barBg = make("Frame", {
			BackgroundColor3 = Color3.fromRGB(45, 48, 58),
			BorderSizePixel = 0,
			Position = UDim2.new(0, 10, 1, -22),
			Size = UDim2.new(1, -20, 0, 12),
		}, card)
		corner(barBg, 6)
		local fill = make("Frame", {
			BackgroundColor3 = t.Color,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(0, 1),
		}, barBg)
		corner(fill, 6)
		cards[t.Name] = { frame = card, stroke = st, fill = fill, score = score }
	end

	timerLabel = label(top, {
		Text = "",
		TextSize = 20,
		Size = UDim2.fromOffset(300, 26),
		LayoutOrder = 2,
		TextStrokeTransparency = 0.5,
	})

	badge = make("Frame", {
		Size = UDim2.fromOffset(240, 30),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.2,
		LayoutOrder = 3,
	}, top)
	corner(badge, 15)
	badgeStroke = stroke(badge, GREY, 2, 0)
	badgeLabel = label(badge, { Size = UDim2.fromScale(1, 1), TextSize = 15, Text = "OUTSIDE ZONE", TextColor3 = GREY })

	-- Bottom left: cash + armor
	local bl = section("BottomLeft", Vector2.new(0, 1), UDim2.new(0, 16, 1, -16), UDim2.fromOffset(240, 90))
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, bl)
	local cashBox = make("Frame", {
		Size = UDim2.fromOffset(190, 44),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		LayoutOrder = 2,
	}, bl)
	corner(cashBox, 10)
	stroke(cashBox, GREEN, 1, 0.6)
	cashLabel = label(cashBox, {
		Text = "$0",
		TextSize = 28,
		Font = FONT_HEAVY,
		TextColor3 = WHITE,
		Size = UDim2.fromScale(1, 1),
	})

	armorFrame = make("Frame", {
		Size = UDim2.fromOffset(190, 22),
		BackgroundColor3 = Color3.fromRGB(45, 48, 58),
		BackgroundTransparency = 0.1,
		LayoutOrder = 1,
		Visible = false,
	}, bl)
	corner(armorFrame, 8)
	stroke(armorFrame, Color3.fromRGB(120, 180, 255), 1, 0.4)
	armorFill = make("Frame", {
		BackgroundColor3 = Color3.fromRGB(90, 160, 255),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	}, armorFrame)
	corner(armorFill, 8)
	armorText = label(armorFrame, {
		Text = "ARMOR",
		TextSize = 13,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		TextStrokeTransparency = 0.5,
	})

	-- Bottom right: ammo
	local bottomOffset = if UserInputService.TouchEnabled then -170 else -16
	local br = section("BottomRight", Vector2.new(1, 1), UDim2.new(1, -16, 1, bottomOffset), UDim2.fromOffset(180, 60))
	ammoFrame = make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		Visible = false,
	}, br)
	corner(ammoFrame, 10)
	stroke(ammoFrame, WHITE, 1, 0.7)
	ammoLabel = label(ammoFrame, {
		Text = "30 / 30",
		TextSize = 32,
		Font = FONT_HEAVY,
		Size = UDim2.fromScale(1, 1),
	})

	-- Right: notification feed
	feed = section("Feed", Vector2.new(1, 0.5), UDim2.new(1, -16, 0.5, -40), UDim2.fromOffset(320, 200))
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, feed)

	-- Winner banner (full screen, not scaled)
	banner = make("Frame", {
		Name = "WinnerBanner",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 50,
	}, gui)
	local bc = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(900, 220),
		ZIndex = 51,
	}, banner)
	table.insert(scales, make("UIScale", {}, bc))
	bannerTitle = label(bc, {
		Text = "",
		Font = FONT_HEAVY,
		TextSize = 96,
		Size = UDim2.new(1, 0, 0, 120),
		ZIndex = 52,
	})
	stroke(bannerTitle, Color3.new(0, 0, 0), 4, 0).ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	bannerSub = label(bc, {
		Text = "",
		TextSize = 32,
		Position = UDim2.fromOffset(0, 130),
		Size = UDim2.new(1, 0, 0, 44),
		ZIndex = 52,
	})

	updateScale()
end

-- Updaters ---------------------------------------------------------------

local function refreshScores()
	local mine = localTeamName()
	for _, t in Config.Teams do
		local c = cards[t.Name]
		local score = gameState:GetAttribute("Score_" .. t.Name)
		score = if type(score) == "number" then score else 0
		c.score.Text = ("%d / %d"):format(score, Config.Match.PointsToWin)
		tween(c.fill, 0.3, { Size = UDim2.fromScale(math.clamp(score / Config.Match.PointsToWin, 0, 1), 1) })
		local isMine = (t.Name == mine)
		c.stroke.Thickness = if isMine then 3 else 1
		c.stroke.Transparency = if isMine then 0 else 0.6
		c.frame.BackgroundTransparency = if isMine then 0.05 else 0.25
	end
end

local function refreshBanner()
	local phase = gameState:GetAttribute("Phase")
	local winner = gameState:GetAttribute("Winner")
	if phase == "Intermission" and type(winner) == "string" and winner ~= "" then
		local t = teamConfig[winner]
		bannerTitle.Text = string.upper(winner) .. " WINS!"
		bannerTitle.TextColor3 = if t then t.Color else WHITE
		banner.Visible = true
	else
		banner.Visible = false
	end
end

local function refreshCash(flash: boolean)
	local v = player:GetAttribute("Cash")
	v = if type(v) == "number" then v else 0
	cashLabel.Text = "$" .. tostring(math.floor(v + 0.5))
	if flash and v > lastCash then
		cashLabel.TextColor3 = GREEN
		tween(cashLabel, 0.7, { TextColor3 = WHITE })
	end
	lastCash = v
end

local function refreshArmor()
	local a = player:GetAttribute("Armor")
	local m = player:GetAttribute("MaxArmor")
	a = if type(a) == "number" then a else 0
	m = if type(m) == "number" and m > 0 then m else Config.Armor.Max
	armorFrame.Visible = a > 0
	armorFill.Size = UDim2.fromScale(math.clamp(a / m, 0, 1), 1)
	armorText.Text = ("ARMOR %d"):format(math.ceil(a))
end

local function hasRifle(): boolean
	local char = player.Character
	if not char then
		return false
	end
	local tool = char:FindFirstChild(Config.Rifle.ToolName)
	return tool ~= nil and tool:IsA("Tool")
end

local function refreshAmmo()
	local show = hasRifle()
	ammoFrame.Visible = show
	if not show then
		return
	end
	if reloading then
		ammoLabel.Text = "RELOADING"
		ammoLabel.TextSize = 24
		ammoLabel.TextColor3 = ORANGE
	else
		ammoLabel.Text = ("%d / %d"):format(ammo, Config.Rifle.MagazineSize)
		ammoLabel.TextSize = 32
		ammoLabel.TextColor3 = if ammo <= math.ceil(Config.Rifle.MagazineSize * 0.2) then KIND_COLORS.error else WHITE
	end
end

local function refreshBadge()
	local zone = player:GetAttribute("Zone")
	if zone == "Hot" then
		badgeLabel.Text = "IN HOTZONE \u{00D7}2"
	elseif zone == "Combat" then
		badgeLabel.Text = "IN COMBAT ZONE"
		badgeLabel.TextColor3 = localTeamColor()
		badgeStroke.Color = localTeamColor()
		badge.BackgroundColor3 = PANEL
	else
		badgeLabel.Text = "OUTSIDE ZONE"
		badgeLabel.TextColor3 = GREY
		badgeStroke.Color = GREY
		badge.BackgroundColor3 = PANEL
	end
end

local function pushNotify(text: string, kind: string)
	feedOrder += 1
	local color = KIND_COLORS[kind] or KIND_COLORS.info

	local item = make("Frame", {
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		LayoutOrder = feedOrder,
	}, feed)
	corner(item, 8)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 4),
	}, item)
	local txt = label(item, {
		Text = text,
		TextColor3 = color,
		TextSize = 17,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local entry = { frame = item, dead = false }
	table.insert(feedItems, entry)

	local function remove(fade: boolean)
		if entry.dead then
			return
		end
		entry.dead = true
		local idx = table.find(feedItems, entry)
		if idx then
			table.remove(feedItems, idx)
		end
		if fade then
			tween(item, 0.4, { BackgroundTransparency = 1 })
			tween(txt, 0.4, { TextTransparency = 1 })
			task.delay(0.45, function()
				item:Destroy()
			end)
		else
			item:Destroy()
		end
	end

	while #feedItems > MAX_FEED do
		local oldest = feedItems[1]
		oldest.dead = true
		table.remove(feedItems, 1)
		oldest.frame:Destroy()
	end
	task.delay(FEED_LIFETIME, function()
		remove(true)
	end)
end

local function onCharacter(char: Model?)
	ammo = Config.Rifle.MagazineSize
	reloading = false
	if char then
		connect(char.ChildAdded, function()
			refreshAmmo()
		end)
		connect(char.ChildRemoved, function()
			refreshAmmo()
		end)
	end
	refreshAmmo()
end

local function frame()
	local now = Workspace:GetServerTimeNow()
	local phase = gameState:GetAttribute("Phase")

	if phase == "Intermission" then
		local ends = gameState:GetAttribute("IntermissionEndsAt")
		local left = math.max(0, math.ceil((if type(ends) == "number" then ends else now) - now))
		timerLabel.Text = "Match over"
		bannerSub.Text = ("Next match in %ds"):format(left)
	else
		local nextAt = gameState:GetAttribute("NextTickAt")
		local left = math.max(0, math.ceil((if type(nextAt) == "number" then nextAt else now) - now))
		timerLabel.Text = ("Next tick in %ds"):format(left)
	end

	if player:GetAttribute("Zone") == "Hot" then
		local k = (math.sin(os.clock() * 6) + 1) / 2
		local c = ORANGE:Lerp(Color3.fromRGB(255, 220, 90), k)
		badgeLabel.TextColor3 = Color3.new(1, 1, 1)
		badge.BackgroundColor3 = ORANGE:Lerp(Color3.fromRGB(120, 60, 0), 1 - k)
		badgeStroke.Color = c
	end

	refreshAmmo()
end

function HudController.Init(_self)
	-- Everything is built in Start (it needs to wait for PlayerGui / GameState).
end

function HudController.Start(_self)
	buildGui()
	gameState = ReplicatedStorage:WaitForChild("GameState") :: Folder

	for _, t in Config.Teams do
		connect(gameState:GetAttributeChangedSignal("Score_" .. t.Name), refreshScores)
	end
	connect(gameState:GetAttributeChangedSignal("Phase"), refreshBanner)
	connect(gameState:GetAttributeChangedSignal("Winner"), refreshBanner)

	connect(player:GetAttributeChangedSignal("Cash"), function()
		refreshCash(true)
	end)
	connect(player:GetAttributeChangedSignal("Armor"), refreshArmor)
	connect(player:GetAttributeChangedSignal("MaxArmor"), refreshArmor)
	connect(player:GetAttributeChangedSignal("Zone"), refreshBadge)
	connect(player:GetPropertyChangedSignal("Team"), function()
		refreshScores()
		refreshBadge()
	end)
	connect(player.CharacterAdded, onCharacter)

	connect(Remotes.event("Notify").OnClientEvent, function(text, kind)
		if type(text) == "string" then
			pushNotify(text, if type(kind) == "string" then kind else "info")
		end
	end)
	connect(Remotes.event("AmmoUpdate").OnClientEvent, function(a, isReloading)
		if type(a) == "number" then
			ammo = a
		end
		reloading = isReloading == true
		refreshAmmo()
	end)

	local cam = Workspace.CurrentCamera
	if cam then
		connect(cam:GetPropertyChangedSignal("ViewportSize"), updateScale)
	end
	connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		local c = Workspace.CurrentCamera
		if c then
			connect(c:GetPropertyChangedSignal("ViewportSize"), updateScale)
			updateScale()
		end
	end)

	-- Initial state
	lastCash = 0
	refreshScores()
	refreshBanner()
	refreshCash(false)
	refreshArmor()
	refreshBadge()
	onCharacter(player.Character)

	connect(RunService.RenderStepped, frame)

	-- Clean up if the local player leaves (rarely relevant on client, but keeps things tidy)
	connect(Players.PlayerRemoving, function(p)
		if p == player then
			for _, c in connections do
				c:Disconnect()
			end
			table.clear(connections)
		end
	end)
end

return HudController
