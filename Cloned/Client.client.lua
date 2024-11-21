local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Modules = ReplicatedStorage:WaitForChild("Modules")

local ClientGun = require(Modules.Guns.ClientGun)
local MiscUtils = require(Modules.Mega.Utils.Misc)
local Logging = require(Modules.Mega.Logging)
local AMS = require(Modules.AMS.Controller)
local Strafer = require(Modules.Strafer)
local ConnManager = require(Modules.Mega.Utils.ConnManager)

local LOG = Logging:new("Turrets.Server")

local LocalPlayer = game.Players.LocalPlayer
local mouse = LocalPlayer:GetMouse()
local isMobile = MiscUtils.getClientPlatform() == "Mobile"

local connections = ConnManager:new()
local tool: Tool = script.Parent
local gun = ClientGun:new(tool)

local isFiring = false
local mouseDown = false

local camera = workspace.CurrentCamera
local mobileCanvas =
	LocalPlayer.PlayerGui:WaitForChild("Mobile"):WaitForChild("Gun")

-- ============== Functions =============

local function setMouseDown(status: boolean)
	mouseDown = status
	AMS.actionLocks.sprinting = status
end

local function getHitFromViewport(x, y)
	local ray = workspace.CurrentCamera:ViewportPointToRay(x, y)
	local partHit, endPosition =
		workspace:FindPartOnRay(Ray.new(ray.Origin, ray.Direction * 10000))
	return endPosition
end

local function onHeartbeat()
	if not mouseDown or isFiring then
		return
	end

	-- No auto re-fire if semi or burst
	isFiring = true
	if
		gun.settings.Gun.FireMode == "Semi"
		or gun.settings.Gun.FireMode == "Burst"
	then
		setMouseDown(false)
	end

	-- Get hit position
	local pos
	if isMobile then
		pos = getHitFromViewport(
			camera.ViewportSize.X / 2,
			camera.ViewportSize.Y / 2
		)
	else
		pos = mouse.Hit.Position
	end

	-- Fire gun
	local success, err = pcall(gun.Fire, gun, pos)
	if not success then
		LOG:Error(
			"Gun failed to fire for client %s: %s",
			LocalPlayer.UserId,
			err
		)
	end

	-- Determine burst
	local n = (gun.settings.BurstSize or 1) - 1
	for i = 1, n do
		task.wait(1 / gun.settings.Gun.FireRate)
		gun:Fire(pos)
	end
	task.wait(gun.settings.BurstDelay or 0)
	isFiring = false
end

local function setupMobile()
	--[[
		NOTE: We should not use context action service here because the camera
		needs to be able to move while firing. Context action service fires the 
		`gameProcessedEvent` when stops the camera from moving. 
	]]
	connections:Add(
		"mouseDown",
		mobileCanvas.Fire.MouseButton1Down:Connect(function()
			setMouseDown(true)
		end)
	)

	connections:Add(
		"mouseUp",
		mobileCanvas.Fire.MouseButton1Up:Connect(function()
			setMouseDown(false)
		end)
	)

	connections:Add(
		"reload",
		mobileCanvas.Reload.MouseButton1Up:Connect(function()
			setMouseDown(false)
			gun:Reload()
		end)
	)

	connections:Add(
		"aim",
		mobileCanvas.Aim.MouseButton1Up:Connect(function()
			gun:ToggleAim(not gun.isAiming)
		end)
	)

	connections:Add(
		"view",
		mobileCanvas.View.MouseButton1Up:Connect(function()
			Strafer:SetShoulderDirection(-1 * Strafer.ShoulderDirection)
		end)
	)
end

local function setupDesktop()
	connections:Add(
		"inputBegan",
		UIS.InputBegan:Connect(function(input, gp)
			if gp then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				setMouseDown(true)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				gun:ToggleAim(true)
			elseif input.KeyCode == Enum.KeyCode.R then
				gun:Reload()
			end
		end)
	)

	connections:Add(
		"inputEnd",
		UIS.InputEnded:Connect(function(input, gp)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				setMouseDown(false)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				gun:ToggleAim(false)
			end
		end)
	)
end

local function onEquip()
	-- Connections
	connections:Add("heartbeat", RunService.Heartbeat:Connect(onHeartbeat))
	if isMobile then
		setupMobile()
	else
		setupDesktop()
	end

	-- Gun
	gun:Equip()
	if isMobile then
		mobileCanvas.Visible = true
	end
end

local function onUnEquip()
	-- Connections
	connections:RemoveAll()

	-- Gun
	gun:Unequip()
	isFiring = false
	setMouseDown(false)
	if isMobile then
		mobileCanvas.Visible = false
	end
end

-- ============== Connections =============

tool.Equipped:Connect(onEquip)
tool.Unequipped:Connect(onUnEquip)
