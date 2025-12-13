local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Modules = ReplicatedStorage:WaitForChild("Modules")

local ClientGun = require(Modules.Guns.ClientGun)

local LocalPlayer = game.Players.LocalPlayer

-- ============== Non-owning player =============

local tool: Tool = script.Parent
local isOwner = (
	tool:IsDescendantOf(LocalPlayer.Backpack)
	or tool:IsDescendantOf(LocalPlayer.Character)
)
if not isOwner then
	ClientGun._setupClient(tool)
	return
end

-- ============== Owning Player =============

local MiscUtils = require(Modules.Mega.Utils.Misc)
local Logging = require(Modules.Mega.Logging)
local PlayerSettings = require(Modules.Mega.Data.PlayerSettings)
local AMS = require(Modules.AMS.Controller)
local Strafer = require(Modules.Strafer)
local ConnManager = require(Modules.Mega.Utils.ConnManager)
local Damage = require(Modules.Damage.Damage)

local SETTINGS = require(ReplicatedStorage.Settings.Guns)
local LOG = Logging:new("Guns.Client")
local AUTOSHOOT_SETTINGS = SETTINGS.AutoShoot

local mouse = LocalPlayer:GetMouse()
local isMobile = MiscUtils.getClientPlatform() == "Mobile"

local connections = ConnManager:new()
local gun = ClientGun:new(tool)

local isFiring = false
local mouseDown = false

local camera = workspace.CurrentCamera
local mobileCanvas = LocalPlayer.PlayerGui:WaitForChild("Mobile"):WaitForChild("Gun")

-- shape cast cache
local shapeCastParams: RaycastParams? = nil
if AUTOSHOOT_SETTINGS then
	shapeCastParams = RaycastParams.new()
	shapeCastParams.FilterType = Enum.RaycastFilterType.Exclude
	shapeCastParams.FilterDescendantsInstances = { LocalPlayer.Character }
end

-- ============== Functions =============

local function setMouseDown(status: boolean)
	mouseDown = status
	AMS.actionLocks.sprinting = status
end

local function getHitFromViewport()
	local x, y = camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2
	local ray = workspace.CurrentCamera:ViewportPointToRay(x, y)
	local partHit, endPosition =
		workspace:FindPartOnRay(Ray.new(ray.Origin, ray.Direction * 10000))
	return endPosition, partHit
end

local function getHitFromCone(): (Vector3?, Instance?)
	if not shapeCastParams then
		return nil, nil
	end

	local baseOrigin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector

	local gunMax = gun.settings.Caster.MaxDistance
	local globalMax = AUTOSHOOT_SETTINGS.MaxLength or 10000
	local maxDistance = math.max(0, math.min(gunMax or globalMax, globalMax))
	if maxDistance <= 0 then
		return nil, nil
	end

	do
		local rayHit =
			workspace:Raycast(baseOrigin, direction * maxDistance, shapeCastParams)
		if rayHit then
			local canDamage, opts =
				Damage.canDamage({ Dealer = LocalPlayer, Taker = rayHit.Instance })
			if canDamage and not AUTOSHOOT_SETTINGS.filterAutoShoot(opts.Taker) then
				return rayHit.Position, rayHit.Instance
			end
		end
	end

	-- 2) fallback: expanding cone sweep
	local epsilon = 1e-3
	local minRadius = AUTOSHOOT_SETTINGS.MinRadius or 0.25
	local radiusAtMax = AUTOSHOOT_SETTINGS.RadiusAtMaxDistance
	if not radiusAtMax or radiusAtMax <= 0 then
		return nil, nil
	end
	local step = AUTOSHOOT_SETTINGS.ConeStep or 16
	local maxClamp = AUTOSHOOT_SETTINGS.MaxClampRadius or 256

	local safeMax = math.max(1e-3, maxDistance)
	local coneTan = radiusAtMax / safeMax

	local traveled = 0
	local nearSeg = math.min(800, maxDistance)
	if nearSeg > 0 then
		local segCenterDist = nearSeg * 0.5
		local radius = math.clamp(
			math.max(minRadius, coneTan * segCenterDist),
			minRadius,
			maxClamp
		)
		local r0 = workspace:Spherecast(
			baseOrigin,
			radius,
			direction * math.max(0, nearSeg - epsilon),
			shapeCastParams
		)
		if r0 then
			return r0.Position, r0.Instance
		end
		traveled += nearSeg
	end

	while traveled < maxDistance do
		local segLen = math.min(step, maxDistance - traveled)
		if segLen <= 0 then
			break
		end

		local segCenterDist = traveled + segLen * 0.5
		local radius = math.clamp(
			math.max(minRadius, coneTan * segCenterDist),
			minRadius,
			maxClamp
		)

		local segOrigin = baseOrigin + direction * traveled
		local result =
			workspace:Spherecast(segOrigin, radius, direction * segLen, shapeCastParams)
		if result then
			return result.Position, result.Instance
		end

		traveled += segLen
	end

	return nil, nil
end

local autoAimPos: Vector3? = nil
local function onHeartbeat()
	if not mouseDown or isFiring then
		return
	end
	isFiring = true

	if gun.settings.Gun.FireMode == "Semi" or gun.settings.Gun.FireMode == "Burst" then
		setMouseDown(false)
	end

	local pos
	if autoAimPos then
		pos = autoAimPos
	elseif isMobile then
		pos = getHitFromViewport()
	else
		pos = mouse.Hit.Position
	end

	local ok, err = pcall(gun.Fire, gun, pos)
	if not ok then
		LOG:Error("Gun failed to fire for client %s: %s", LocalPlayer.UserId, err)
	end

	local n = (gun.settings.Gun.BurstSize or 1) - 1
	for i = 1, n do
		task.wait(1 / gun.settings.Gun.FireRate)
		gun:Fire(pos)
	end
	task.wait(gun.settings.BurstDelay or 0)
	isFiring = false
end

local function setupMobile()
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

local lastAutoInterval = tick()
local function setupAutoshoot()
	if not PlayerSettings:Lookup("AutoShoot", true) then
		return
	end

	local thisInterval = tick()
	lastAutoInterval = thisInterval
	local isAutofiring = false

	task.spawn(function()
		while gun.isEquipped and thisInterval == lastAutoInterval do
			if not PlayerSettings:Lookup("AutoShoot", true) then
				task.wait(3)
				isAutofiring = false
				mouseDown = false
				autoAimPos = nil
				continue
			end

			if isAutofiring then
				task.wait(AUTOSHOOT_SETTINGS.PollRates.Firing)
			else
				task.wait(AUTOSHOOT_SETTINGS.PollRates.NotFiring)
			end

			local aimPos: Vector3? = nil
			local hit: Instance? = nil

			if shapeCastParams then
				aimPos, hit = getHitFromCone()
			else
				if isMobile then
					aimPos, hit = getHitFromViewport()
				else
					hit = mouse.Target
					aimPos = hit and mouse.Hit.Position or nil
				end
			end

			if not hit then
				mouseDown = false
				isAutofiring = false
				autoAimPos = nil
				continue
			end

			local canDamage, options = Damage.canDamage({
				Dealer = LocalPlayer,
				Taker = hit,
			})

			if not canDamage or AUTOSHOOT_SETTINGS.filterAutoShoot(options.Taker) then
				if isAutofiring then
					mouseDown = false
					isAutofiring = false
					autoAimPos = nil
				end
				continue
			end

			autoAimPos = aimPos or hit.Position
			mouseDown = true
			isAutofiring = true
		end
	end)
end

local function onEquip()
	connections:Add("heartbeat", RunService.Heartbeat:Connect(onHeartbeat))
	if isMobile then
		setupMobile()
	else
		setupDesktop()
	end

	gun:Equip()
	local autoShootMode = AUTOSHOOT_SETTINGS.Mode
	if isMobile then
		mobileCanvas.Visible = true
		setupMobile()
		if autoShootMode == "Mobile" then
			setupAutoshoot()
		end
	else
		setupDesktop()
		if autoShootMode == "Any" then
			setupAutoshoot()
		end
	end
end

local function onUnEquip()
	connections:RemoveAll()
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
