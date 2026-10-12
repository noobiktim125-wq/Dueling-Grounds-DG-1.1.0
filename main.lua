local Testy = loadstring(game:HttpGet("https://raw.githubusercontent.com/WareSploit/Testy-Library/main/main.lua"))()

Testy:SetTitle("Dueling Grounds")
Testy:SetVersion("DG Combat v1.1.0")

Testy:SetTabTitle("Main", "Combat")
Testy:SetTabTitle("Player", "Actions")
Testy:SetTabTitle("Settings", "Config")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local function new(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do i[k] = v end
	if parent then i.Parent = parent end
	return i
end

local DG = {
	Alive = true,
	AutoParry = false,
	Targeting = false,
	HitboxReach = false,
	ReachRange = 9,
	Rate = 100,
	ParryCount = 0,
	BlockCount = 0,
	IdleCount = 0,
	_lastParryTick = tick(),
	CurrentTarget = nil,
	Connections = {},
	Available = false,
	GameManager = nil,
	TargetLockController = nil,
	MatchController = nil,
}

local ResolveImpact, RequestHitboxOnImpact
do
	local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if Remotes then
		local PC = Remotes:FindFirstChild("PlayerCharacter")
		if PC then
			local Req = PC:FindFirstChild("Request")
			if Req then
				ResolveImpact = Req:FindFirstChild("ResolveImpact")
				RequestHitboxOnImpact = Req:FindFirstChild("RequestHitboxOnImpact")
			end
		end
	end
	DG.Available = ResolveImpact ~= nil and RequestHitboxOnImpact ~= nil
end

local refreshStats -- forward declaration

local function refreshControllers()
	if DG.GameManager and DG.TargetLockController and DG.MatchController then return true end
	if not DG.GameManager then
		local ok, manager = pcall(function()
			return require(ReplicatedStorage:WaitForChild("GameManager", 5))
		end)
		if ok then DG.GameManager = manager end
	end
	if DG.GameManager then
		pcall(function()
			DG.TargetLockController = DG.GameManager:GetController("TargetLockController")
			DG.MatchController = DG.GameManager:GetController("MatchController")
		end)
	end
	return DG.TargetLockController ~= nil
end

local function getRoot()
	local char = LocalPlayer.Character
	return char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
end

local function isEnemy(model, player)
	if DG.MatchController and type(DG.MatchController.IsCharacterEnemyOfLocalPlayer) == "function" then
		local ok, enemy = pcall(function() return DG.MatchController:IsCharacterEnemyOfLocalPlayer(model) end)
		if ok then return enemy == true end
	end
	if player and LocalPlayer.Team and player.Team then return player.Team ~= LocalPlayer.Team end
	return player ~= LocalPlayer
end

local function getClosestEnemy()
	local localRoot = getRoot()
	if not localRoot then return nil end

	local closest, minDist = nil, math.huge
	for _, model in CollectionService:GetTagged("CustomCharacter") do
		if model:IsDescendantOf(workspace) and model:GetAttribute("IsDead") ~= true then
			local userId = model:GetAttribute("UserId")
			local player = userId and Players:GetPlayerByUserId(userId)
			if userId ~= LocalPlayer.UserId and isEnemy(model, player) then
				local part = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
				local hum = model:FindFirstChildOfClass("Humanoid")
				if part and hum and hum.Health > 0 then
					local dist = (part.Position - localRoot.Position).Magnitude
					if dist < minDist then
						minDist = dist
						closest = { Part = part, Distance = dist }
					end
				end
			end
		end
	end
	return closest
end

local resolutionHookTarget, resolutionHookOriginal, resolutionHookInstalled
local function installImpactHook()
	if resolutionHookInstalled or not DG.AutoParry then return end
	if type(hookfunction) ~= "function" or type(newcclosure) ~= "function" then return end

	local ok, handler = pcall(function()
		return DG.GameManager:GetController("CharacterController"):GetLocalCharacterHandler()
	end)
	local manager = ok and handler and handler.ActionManager
	if not manager or type(manager._computeImpactResolution) ~= "function" then return end

	resolutionHookTarget = manager._computeImpactResolution
	local okHook, original = pcall(hookfunction, resolutionHookTarget, newcclosure(function(self, impactData)
		if not DG.Alive or not DG.AutoParry then return resolutionHookOriginal(self, impactData) end

		local characterHandler = self.CharacterHandler
		local pParry, pBlock = characterHandler.IsParrying, characterHandler.IsBlocking
		characterHandler.IsParrying = true
		characterHandler.IsBlocking = true

		local results = table.pack(resolutionHookOriginal(self, impactData))
		characterHandler.IsParrying = pParry
		characterHandler.IsBlocking = pBlock
		return table.unpack(results, 1, results.n)
	end))

	if okHook then
		resolutionHookOriginal = original
		resolutionHookInstalled = true
	end
end

if DG.Available and type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" and type(newcclosure) == "function" then
	local oldNamecall
	oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		local method = getnamecallmethod()

		if DG.Alive and DG.AutoParry and self == ResolveImpact and method == "FireServer" then
			local args = { ... }
			if args[2] ~= "Parry" and args[2] ~= "Dodge" then
				local roll = math.random(1, 100)
				if roll <= DG.Rate then
					args[2] = "Parry"
					DG.ParryCount = DG.ParryCount + 1
				else
					DG.BlockCount = DG.BlockCount + 1
				end
				DG._lastParryTick = tick()
				if refreshStats then refreshStats() end
			end
			return oldNamecall(self, table.unpack(args))
		end

		if DG.Alive and DG.HitboxReach and self == RequestHitboxOnImpact and method == "FireServer" then
			local args = { ... }
			local target = DG.CurrentTarget
			local localRoot = getRoot()
			if localRoot and target and target.Part and target.Part:IsDescendantOf(workspace) and typeof(args[1]) == "CFrame" then
				local offset = target.Part.Position - localRoot.Position
				local distance = offset.Magnitude
				if distance > 0.05 and distance <= DG.ReachRange then
					local reportedOrigin = target.Part.Position - (offset.Unit * 2.75)
					args[1] = CFrame.lookAt(reportedOrigin, target.Part.Position)
					return oldNamecall(self, table.unpack(args))
				end
			end
		end

		return oldNamecall(self, ...)
	end))
end

local idleAccum = 0
table.insert(DG.Connections, RunService.Heartbeat:Connect(function(dt)
	if not DG.Alive then return end
	refreshControllers()
	installImpactHook()

	if DG.Targeting then
		local target = getClosestEnemy()
		DG.CurrentTarget = target
		if DG.TargetLockController then
			pcall(function() DG.TargetLockController:SetTarget(target and target.Part or nil) end)
		end
	end

	if DG.AutoParry then
		if tick() - DG._lastParryTick > 1 then
			idleAccum = idleAccum + dt
			if idleAccum >= 1 then
				idleAccum = 0
				DG.IdleCount = DG.IdleCount + 1
				if refreshStats then refreshStats() end
			end
		else
			idleAccum = 0
		end
	end
end))

local combat = Testy:GetPage("Main")
local actions = Testy:GetPage("Player")
local config = Testy:GetPage("Settings")

Testy:CreateLabel(combat, "── Combat ──")

Testy:CreateToggle(combat, "Auto Parry", false, function(state)
	DG.AutoParry = state
	Testy.Flags.AutoParry = state
	if state then installImpactHook() end
	Testy:Notify("Auto Parry", state and "Enabled" or "Disabled", state and "success" or "info", 2)
end)

Testy:CreateToggle(combat, "Targeting", false, function(state)
	DG.Targeting = state
	Testy.Flags.Targeting = state
	if not state and DG.TargetLockController then
		pcall(function() DG.TargetLockController:SetTarget(nil) end)
	end
end)

Testy:CreateToggle(combat, "Hitbox Reach", false, function(state)
	DG.HitboxReach = state
	Testy.Flags.HitboxReach = state
end)

Testy:CreateSlider(combat, "Reach Range", 3, 30, 9, function(value)
	DG.ReachRange = tonumber(value) or 9
	Testy.Flags.ReachRange = value
end)

Testy:CreateLabel(combat, "── Parry Rate ──")

local rateRow = new("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundColor3 = Testy.Colors.Surface,
	BorderSizePixel = 0,
	Parent = combat,
})
new("UICorner", { CornerRadius = UDim.new(0, 4) }, rateRow)

new("TextLabel", {
	Size = UDim2.new(0, 80, 1, 0),
	Position = UDim2.new(0, 10, 0, 0),
	BackgroundTransparency = 1,
	Text = "Rate",
	TextColor3 = Testy.Colors.Text,
	TextSize = 13,
	FontFace = Testy.Font,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = rateRow,
})

local minusBtn = new("TextButton", {
	Size = UDim2.fromOffset(26, 26),
	Position = UDim2.new(1, -122, 0.5, -13),
	BackgroundColor3 = Testy.Colors.SurfaceHover,
	BorderSizePixel = 0,
	Text = "-",
	TextColor3 = Testy.Colors.Text,
	TextSize = 16,
	FontFace = Testy.FontBold,
	AutoButtonColor = false,
	Parent = rateRow,
})
new("UICorner", { CornerRadius = UDim.new(0, 4) }, minusBtn)

local rateValue = new("TextLabel", {
	Size = UDim2.new(0, 50, 1, 0),
	Position = UDim2.new(1, -94, 0, 0),
	BackgroundTransparency = 1,
	Text = "100",
	TextColor3 = Testy.Colors.Accent,
	TextSize = 14,
	FontFace = Testy.FontBold,
	TextXAlignment = Enum.TextXAlignment.Center,
	Parent = rateRow,
})

local plusBtn = new("TextButton", {
	Size = UDim2.fromOffset(26, 26),
	Position = UDim2.new(1, -42, 0.5, -13),
	BackgroundColor3 = Testy.Colors.SurfaceHover,
	BorderSizePixel = 0,
	Text = "+",
	TextColor3 = Testy.Colors.Text,
	TextSize = 16,
	FontFace = Testy.FontBold,
	AutoButtonColor = false,
	Parent = rateRow,
})
new("UICorner", { CornerRadius = UDim.new(0, 4) }, plusBtn)

Testy:Hover(minusBtn, Testy.Colors.SurfaceHover, Testy.Colors.Accent)
Testy:Hover(plusBtn, Testy.Colors.SurfaceHover, Testy.Colors.Accent)

local function setRate(newRate)
	DG.Rate = math.clamp(math.floor(newRate + 0.5), 0, 100)
	rateValue.Text = tostring(DG.Rate)
	Testy.Flags.Rate = DG.Rate
end

minusBtn.MouseButton1Click:Connect(function() setRate(DG.Rate - 5) end)
plusBtn.MouseButton1Click:Connect(function() setRate(DG.Rate + 5) end)

local statsRow = new("Frame", {
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundColor3 = Testy.Colors.Surface,
	BorderSizePixel = 0,
	Parent = combat,
})
new("UICorner", { CornerRadius = UDim.new(0, 4) }, statsRow)

local function makeStat(xPos, label, color)
	local holder = new("Frame", {
		Size = UDim2.new(0, 100, 1, 0),
		Position = UDim2.new(0, xPos, 0, 0),
		BackgroundTransparency = 1,
		Parent = statsRow,
	})

	new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0, 0, 0, 6),
		BackgroundTransparency = 1,
		Text = label,
		TextColor3 = Testy.Colors.Dim,
		TextSize = 11,
		FontFace = Testy.Font,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = holder,
	})

	local value = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 0, 18),
		BackgroundTransparency = 1,
		Text = "0",
		TextColor3 = color,
		TextSize = 15,
		FontFace = Testy.FontBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = holder,
	})

	return value
end

local parryStat = makeStat(6, "Parry", Testy.Colors.Green)
local blockStat = makeStat(112, "Block", Testy.Colors.Yellow)
local idleStat  = makeStat(218, "Idle", Testy.Colors.Dim)

refreshStats = function()
	rateValue.Text = tostring(DG.Rate)
	parryStat.Text = tostring(DG.ParryCount)
	blockStat.Text = tostring(DG.BlockCount)
	idleStat.Text = tostring(DG.IdleCount)
end
refreshStats()

Testy:CreateButton(combat, "Reset Stats", function()
	DG.ParryCount = 0
	DG.BlockCount = 0
	DG.IdleCount = 0
	refreshStats()
	Testy:Notify("Stats", "Counters reset", "info", 2)
end)

Testy:CreateLabel(combat, "── Info ──")
Testy:CreateLabel(combat, "DG Available: " .. tostring(DG.Available))
Testy:CreateLabel(combat, "Rate = chance to parry per hit")

Testy:CreateLabel(actions, "── Quick Actions ──")

Testy:CreateButton(actions, "Lock Closest Target", function()
	local target = DG.CurrentTarget
	if target then
		Testy:Notify("Target", string.format("Locked @ %.1f studs", target.Distance), "success", 2)
	else
		Testy:Notify("Target", "No enemy found", "warning", 2)
	end
end)

Testy:CreateButton(actions, "Clear Target", function()
	DG.Targeting = false
	if DG.TargetLockController then
		pcall(function() DG.TargetLockController:SetTarget(nil) end)
	end
	Testy:Notify("Target", "Cleared", "info", 2)
end)

Testy:CreateButton(actions, "Reset Character", function()
	local char = LocalPlayer.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then hum.Health = 0 end
	end
end)

Testy:CreateButton(actions, "Panic - Disable All", function()
	DG.AutoParry = false
	DG.Targeting = false
	DG.HitboxReach = false
	if DG.TargetLockController then
		pcall(function() DG.TargetLockController:SetTarget(nil) end)
	end
	Testy:Notify("Panic", "All functions disabled", "warning", 2)
end)

Testy:CreateLabel(config, "── Configuration ──")
Testy:CreateConfig(config, "dueling_config.json")

Testy:CreateLabel(config, "── Keybinds ──")

Testy:CreateKeybind(config, "Panic Key", Enum.KeyCode.Delete, function()
	DG.AutoParry = false
	DG.Targeting = false
	DG.HitboxReach = false
	if DG.TargetLockController then
		pcall(function() DG.TargetLockController:SetTarget(nil) end)
	end
	Testy:Notify("Panic", "Disabled via keybind", "warning", 2)
end)

Testy:CreateKeybind(config, "Toggle UI", Enum.KeyCode.RightShift, function()
	Testy.MainFrame.Visible = not Testy.MainFrame.Visible
end)

function DG:Unload()
	self.Alive = false
	for _, conn in ipairs(self.Connections) do
		pcall(function() conn:Disconnect() end)
	end
	if self.TargetLockController then
		pcall(function() self.TargetLockController:SetTarget(nil) end)
	end
	self.Connections = {}
end

if getgenv then
	getgenv().DuelingGrounds = DG
end

Testy:Notify("Dueling Grounds", "DG loaded | Available: " .. tostring(DG.Available), DG.Available and "success" or "warning", 4)
