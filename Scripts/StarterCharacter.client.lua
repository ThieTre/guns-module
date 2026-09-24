local LocalPlayer = game.Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui

local scope = PlayerGui:WaitForChild("Scope"):WaitForChild("Scope")
local ret = scope.Reticle
local left = scope.Left
local right = scope.Right
local top = scope.Top
local bottom = scope.Bottom
local distanceText = scope.Reticle.Distance
local statusText = scope.Reticle.Status
local hotbarUi = PlayerGui:WaitForChild("Turrets"):WaitForChild("Hotbar")

local firePointObjValue = Instance.new("ObjectValue")
firePointObjValue.Name = "FirePoint"
firePointObjValue.Parent = scope

local lastFirepointUpdate

local RED = Color3.new(1, 0.403922, 0.403922)
local GREEN = Color3.new(0.4, 1, 0.541176)

scope.Visible = true

local function round(n)
	return math.floor(n + 0.5)
end

local function setUi()
	-- Integer pixel sizes
	local scopeW, scopeH = round(scope.AbsoluteSize.X), round(scope.AbsoluteSize.Y)
	local retW, retH = round(ret.AbsoluteSize.X), round(ret.AbsoluteSize.Y)

	local retX = math.max(0, math.floor((scopeW - retW) / 2))
	local retY = math.max(0, math.floor((scopeH - retH) / 2))
	local retRight = math.min(scopeW, retX + retW)
	local retBottom = math.min(scopeH, retY + retH)
	local centralW = math.max(0, retRight - retX)

	ret.AnchorPoint = Vector2.zero
	ret.Position = UDim2.fromOffset(retX, retY)

	-- Left / Right
	left.AnchorPoint = Vector2.new(0, 0)
	left.Position = UDim2.fromOffset(0, 0)
	left.Size = UDim2.fromOffset(retX, scopeH)

	right.AnchorPoint = Vector2.new(0, 0)
	right.Position = UDim2.fromOffset(retRight, 0)
	right.Size = UDim2.fromOffset(math.max(0, scopeW - retRight), scopeH)

	-- Top / Bottom (only between left/right)
	top.AnchorPoint = Vector2.new(0, 0)
	top.Position = UDim2.fromOffset(retX, 0)
	top.Size = UDim2.fromOffset(centralW, retY)

	bottom.AnchorPoint = Vector2.new(0, 0)
	bottom.Position = UDim2.fromOffset(retX, retBottom)
	bottom.Size = UDim2.fromOffset(centralW, math.max(0, scopeH - retBottom))
end

local function onFirePointChange()
	local thisFirePointUpdate = tick()
	lastFirepointUpdate = thisFirePointUpdate

	local firePoint = firePointObjValue.Value
	distanceText.Visible = firePoint ~= nil
	statusText.Visible = firePoint ~= nil
	if not firePoint then
		return
	end

	local mouseAttach = workspace.Terrain.MouseAttachment
	local gunSettings = require(firePoint.Parent.Parent.Settings)
	local maxDistance = gunSettings.Caster.MaxDistance

	while thisFirePointUpdate == lastFirepointUpdate do
		-- Evaluate distance
		local distance = (firePoint.WorldPosition - mouseAttach.WorldPosition).Magnitude
		distanceText.Text = `{math.round(distance)} studs`
		if distance > maxDistance then
			distanceText.TextColor3 = RED
			statusText.TextColor3 = RED
		else
			distanceText.TextColor3 = Color3.new(1, 1, 1)
		end

		local fireBlockedUi = firePoint:FindFirstChild("FireBlocked")
		local ancestorModel = firePoint:FindFirstAncestorOfClass("Model")

		-- Evaluate status
		if distance > maxDistance then
			statusText.Text = "Out of range"
			statusText.TextColor3 = RED
		elseif ancestorModel:GetAttribute("IsReloading") then
			statusText.Text = "Reloading"
			statusText.TextColor3 = RED
		elseif fireBlockedUi and fireBlockedUi.Enabled then
			if fireBlockedUi:GetAttribute("Locked") then
				statusText.Text = "Lock Required"
			else
				statusText.Text = "Blocked"
			end
			statusText.TextColor3 = RED
		else
			statusText.Text = "Ready"
			statusText.TextColor3 = GREEN
		end

		task.wait(0.5)
	end
end

setUi()

scope:GetPropertyChangedSignal("AbsoluteSize"):Connect(setUi)
ret:GetPropertyChangedSignal("AbsoluteSize"):Connect(setUi)
firePointObjValue:GetPropertyChangedSignal("Value"):Connect(onFirePointChange)
