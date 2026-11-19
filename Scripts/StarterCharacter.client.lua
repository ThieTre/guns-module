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

local function setUi()
	local scopeW, scopeH = scope.AbsoluteSize.X, scope.AbsoluteSize.Y
	if scopeW <= 0 or scopeH <= 0 then
		return
	end
	local retW, retH = ret.AbsoluteSize.X, ret.AbsoluteSize.Y

	-- Share the image's exact edges; overlapping translucent layers creates dark seams.
	-- Scale coordinates keep screen-pixel measurements valid under ancestor UIScales.
	local retX = math.clamp((scopeW - retW) / (2 * scopeW), 0, 0.5)
	local retY = math.clamp((scopeH - retH) / (2 * scopeH), 0, 0.5)
	local retRight = 1 - retX
	local retBottom = 1 - retY
	local centralW = math.max(0, retRight - retX)

	ret.AnchorPoint = Vector2.new(0.5, 0.5)
	ret.Position = UDim2.fromScale(0.5, 0.5)

	-- Left / Right
	left.AnchorPoint = Vector2.new(0, 0)
	left.Position = UDim2.fromScale(0, 0)
	left.Size = UDim2.fromScale(retX, 1)

	right.AnchorPoint = Vector2.new(0, 0)
	right.Position = UDim2.fromScale(retRight, 0)
	right.Size = UDim2.fromScale(1 - retRight, 1)

	-- Top / Bottom (only between left/right)
	top.AnchorPoint = Vector2.new(0, 0)
	top.Position = UDim2.fromScale(retX, 0)
	top.Size = UDim2.fromScale(centralW, retY)

	bottom.AnchorPoint = Vector2.new(0, 0)
	bottom.Position = UDim2.fromScale(retX, retBottom)
	bottom.Size = UDim2.fromScale(centralW, 1 - retBottom)
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
