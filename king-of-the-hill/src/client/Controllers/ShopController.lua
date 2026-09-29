-- ShopController: centered shop panel opened by the server's OpenShop event.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local ShopController = {}

local player = Players.LocalPlayer
local CLOSE_DISTANCE = 20
local MESSAGE_TIME = 2

local COLOR_PANEL = Color3.fromRGB(28, 30, 36)
local COLOR_CARD = Color3.fromRGB(44, 47, 56)
local COLOR_BUY = Color3.fromRGB(46, 160, 82)
local COLOR_DISABLED = Color3.fromRGB(85, 85, 90)

local gui: ScreenGui
local panel: Frame
local titleLabel: TextLabel
local list: Frame
local messageLabel: TextLabel

local isOpen = false
local openPos: Vector3? = nil
local buying = false
local messageToken = 0
local distanceConn: RBXScriptConnection? = nil
local cards: { { id: string, price: number, button: TextButton } } = {}

local function getCash(): number
	local v = player:GetAttribute("Cash")
	if type(v) == "number" then
		return v
	end
	return 0
end

local function getRootPos(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function refreshButtons()
	local cash = getCash()
	for _, card in cards do
		local canBuy = cash >= card.price
		card.button.BackgroundColor3 = if canBuy then COLOR_BUY else COLOR_DISABLED
		card.button.TextTransparency = if canBuy then 0 else 0.4
		card.button.Interactable = canBuy
	end
end

local function showMessage(text: string, good: boolean)
	messageToken += 1
	local token = messageToken
	messageLabel.Text = text
	messageLabel.TextColor3 = if good then Color3.fromRGB(120, 230, 140) else Color3.fromRGB(255, 120, 110)
	task.delay(MESSAGE_TIME, function()
		if messageToken == token then
			messageLabel.Text = ""
		end
	end)
end

local function close()
	if not isOpen then
		return
	end
	isOpen = false
	openPos = nil
	gui.Enabled = false
	if distanceConn then
		distanceConn:Disconnect()
		distanceConn = nil
	end
	messageToken += 1
	messageLabel.Text = ""
end

local function buy(itemId: string, price: number)
	if buying or getCash() < price then
		return
	end
	buying = true
	local ok, res, msg = pcall(function()
		return Remotes.func("Purchase"):InvokeServer(itemId)
	end)
	buying = false
	if ok then
		showMessage(if type(msg) == "string" then msg else "Done", res == true)
	else
		showMessage("Purchase failed", false)
	end
	refreshButtons()
end

local function makeCard(itemId: string, order: number)
	local item = Config.Shop[itemId]
	if not item then
		return
	end
	local card = Instance.new("Frame")
	card.Name = itemId
	card.LayoutOrder = order
	card.Size = UDim2.new(1, 0, 0, 64)
	card.BackgroundColor3 = COLOR_CARD
	card.BorderSizePixel = 0
	card.Parent = list
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = card

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(14, 8)
	name.Size = UDim2.new(1, -130, 0, 26)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 20
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = Color3.new(1, 1, 1)
	name.Text = item.Name
	name.Parent = card

	local price = Instance.new("TextLabel")
	price.BackgroundTransparency = 1
	price.Position = UDim2.fromOffset(14, 34)
	price.Size = UDim2.new(1, -130, 0, 22)
	price.Font = Enum.Font.GothamMedium
	price.TextSize = 16
	price.TextXAlignment = Enum.TextXAlignment.Left
	price.TextColor3 = Color3.fromRGB(120, 230, 140)
	price.Text = "$" .. tostring(item.Price)
	price.Parent = card

	local button = Instance.new("TextButton")
	button.Name = "Buy"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -12, 0.5, 0)
	button.Size = UDim2.fromOffset(92, 44)
	button.BackgroundColor3 = COLOR_BUY
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Text = "Buy"
	button.Parent = card
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 6)
	bc.Parent = button
	button.Activated:Connect(function()
		buy(itemId, item.Price)
	end)

	table.insert(cards, { id = itemId, price = item.Price, button = button })
end

local function open(vendorType: string)
	local order = Config.ShopOrder[vendorType]
	if not order then
		return
	end
	local pos = getRootPos()
	if not pos then
		return
	end
	-- rebuild cards
	for _, c in list:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	table.clear(cards)
	for i, itemId in order do
		makeCard(itemId, i)
	end
	titleLabel.Text = if vendorType == "Vehicle" then "Vehicle Vendor" else "Gear Vendor"
	messageLabel.Text = ""
	messageToken += 1
	openPos = pos
	isOpen = true
	gui.Enabled = true
	refreshButtons()

	if distanceConn then
		distanceConn:Disconnect()
	end
	distanceConn = RunService.Heartbeat:Connect(function()
		local now = getRootPos()
		if not now or not openPos or (now - openPos).Magnitude > CLOSE_DISTANCE then
			close()
		end
	end)
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "ShopGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(360, 300)
	panel.BackgroundColor3 = COLOR_PANEL
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(360, 300)
	limit.MinSize = Vector2.new(260, 240)
	limit.Parent = panel

	titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.fromOffset(16, 10)
	titleLabel.Size = UDim2.new(1, -72, 0, 34)
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextSize = 24
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextColor3 = Color3.new(1, 1, 1)
	titleLabel.Text = "Vendor"
	titleLabel.Parent = panel

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -10, 0, 8)
	closeButton.Size = UDim2.fromOffset(40, 40)
	closeButton.BackgroundColor3 = Color3.fromRGB(170, 55, 50)
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 20
	closeButton.TextColor3 = Color3.new(1, 1, 1)
	closeButton.Text = "X"
	closeButton.Parent = panel
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 8)
	cc.Parent = closeButton
	closeButton.Activated:Connect(close)

	list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(16, 58)
	list.Size = UDim2.new(1, -32, 1, -108)
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	messageLabel = Instance.new("TextLabel")
	messageLabel.BackgroundTransparency = 1
	messageLabel.AnchorPoint = Vector2.new(0.5, 1)
	messageLabel.Position = UDim2.new(0.5, 0, 1, -10)
	messageLabel.Size = UDim2.new(1, -32, 0, 30)
	messageLabel.Font = Enum.Font.GothamMedium
	messageLabel.TextSize = 16
	messageLabel.TextWrapped = true
	messageLabel.TextColor3 = Color3.new(1, 1, 1)
	messageLabel.Text = ""
	messageLabel.Parent = panel
end

function ShopController.Init(_self) end

function ShopController.Start(_self)
	buildGui()

	Remotes.event("OpenShop").OnClientEvent:Connect(function(vendorType)
		if type(vendorType) == "string" then
			open(vendorType)
		end
	end)

	player:GetAttributeChangedSignal("Cash"):Connect(function()
		if isOpen then
			refreshButtons()
		end
	end)

	UserInputService.InputBegan:Connect(function(input)
		if not isOpen then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			close()
		end
	end)

	player.CharacterRemoving:Connect(close)
end

return ShopController
