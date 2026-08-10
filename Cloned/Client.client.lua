local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Modules = ReplicatedStorage:WaitForChild("Modules")

local ClientGun = require(Modules.Guns.ClientGun)

local LocalPlayer = game.Players.LocalPlayer

if not LocalPlayer.Character then
	LocalPlayer.CharacterAdded:Wait()
end

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
local Keybinds = require(Modules.Mega.Interface.Keybinds)
local Damage = require(Modules.Damage.Damage)
local GuidedTargeting = require(Modules.Casting.GuidedTargeting)

local SETTINGS = require(ReplicatedStorage.Settings.Guns)
local LOG = Logging:new("Guns.Client")
local AUTOSHOOT_SETTINGS = SETTINGS.AutoShoot

local mouse = LocalPlayer:GetMouse()
local platform = MiscUtils.getClientPlatform()
local isMobile = platform == "Mobile"
local hasController = MiscUtils.isGamepadConnected()
local DRONE_EXIT_KEY = Enum.KeyCode.E
local DRONE_DETONATE_KEY = Enum.KeyCode.R
local DRONE_EXIT_GAMEPAD_KEY = Enum.KeyCode.ButtonB
local DRONE_DETONATE_GAMEPAD_KEY = Enum.KeyCode.ButtonX

local connections = ConnManager:new()
local gun = ClientGun:new(tool)
local guidedTargeting = nil

local isFiring = false
local fireSessionId = 0
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

local function shouldShowMobileCanvas(): boolean
	return isMobile and not hasController
end

local function refreshMobileCanvasVisibility()
	mobileCanvas.Visible = gun.isEquipped and shouldShowMobileCanvas()
end

local function useViewportAim(): boolean
	return isMobile or hasController
end

-- ============== Functions =============

local function setMouseDown(status: boolean)
	mouseDown = status
	AMS.actionLocks.sprinting = status
	if not status and not isFiring then
		gun:ResetFireRateRamp()
	end
end

local function handleControlledDroneInput(input: InputObject): boolean
	if not gun:IsPilotingControlledDrone() then
		return false
	end

	local key = input.KeyCode
	if key == DRONE_EXIT_KEY or key == DRONE_EXIT_GAMEPAD_KEY then
		setMouseDown(false)
		gun:ExitControlledDrone()
	elseif key == DRONE_DETONATE_KEY or key == DRONE_DETONATE_GAMEPAD_KEY then
		setMouseDown(false)
		gun:DetonateControlledDrone()
	end

	return true
end

local function isVehicleSeat(seat: BasePart?): boolean
	local vehicle = seat and seat:FindFirstAncestorWhichIsA("Model")
	return vehicle ~= nil and vehicle:HasTag("Vehicle")
end

local function setupControlledDroneSeatExit()
	local character = LocalPlayer.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then
		return
	end

	local previousSeat = humanoid.SeatPart
	connections:Add(
		"controlledDroneSeatExit",
		humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
			local seat = humanoid.SeatPart
			if
				not seat
				and previousSeat
				and isVehicleSeat(previousSeat)
				and (gun:IsPilotingControlledDrone() or gun:HasActiveControlledDrone())
			then
				setMouseDown(false)
				gun:ExitControlledDrone()
			end
			previousSeat = seat
		end)
	)
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

local function getAimRay(): (Vector3, Vector3)
	if useViewportAim() then
		local x, y = camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2
		local ray = camera:ViewportPointToRay(x, y)
		return ray.Origin, ray.Direction
	end

	local ray = mouse.UnitRay
	return ray.Origin, ray.Direction
end

local function getControlledDroneAimPosition(): Vector3
	local maxDistance = gun.settings.Caster.MaxDistance or 10000
	return camera.CFrame.Position + camera.CFrame.LookVector * maxDistance
end

local autoAimPos: Vector3? = nil
local function onHeartbeat()
	local isPilotingControlledDrone = gun:IsPilotingControlledDrone()
	local isProjectileLimitBlocked = gun:IsProjectileLaunchBlockedByActiveLimit()
	gun:SetActiveProjectileLimitBlocked(isProjectileLimitBlocked)

	if guidedTargeting and not isPilotingControlledDrone then
		local aimOrigin, aimDirection = getAimRay()
		guidedTargeting:Update(aimOrigin, aimDirection)
	end

	if isPilotingControlledDrone then
		setMouseDown(false)
		return
	end

	if not mouseDown or isFiring or isProjectileLimitBlocked then
		if not isFiring and (not mouseDown or isProjectileLimitBlocked) then
			gun:ResetFireRateRamp()
		end
		return
	end
	isFiring = true
	local thisFireSessionId = fireSessionId

	if gun.settings.Gun.FireMode == "Semi" or gun.settings.Gun.FireMode == "Burst" then
		setMouseDown(false)
	end

	local pos
	if autoAimPos then
		pos = autoAimPos
	elseif useViewportAim() then
		pos = getHitFromViewport()
	else
		pos = mouse.Hit.Position
	end

	local ok, firedOrErr = pcall(gun.Fire, gun, pos)
	if not ok then
		LOG:Error(
			"Gun failed to fire for client %s: %s",
			LocalPlayer.UserId,
			firedOrErr
		)
	end

	if ok and firedOrErr and gun:_UsesBurstFireRate() then
		local burstDelay = gun:_GetBurstDelay()
		for _ = 2, gun:_GetBurstSize() do
			task.wait(burstDelay)
			if thisFireSessionId ~= fireSessionId or not gun.isEquipped then
				if thisFireSessionId == fireSessionId then
					isFiring = false
				end
				return
			end
			local followPos = pos
			if gun:IsPilotingControlledDrone() then
				followPos = getControlledDroneAimPosition()
			end
			if not gun:Fire(followPos, { ignoreFireCheck = true }) then
				break
			end
		end

		local burstCooldown = gun:_GetFireCooldownDuration()
		gun:_LockFireCooldown(burstCooldown)
		task.wait(burstCooldown)
	elseif ok and firedOrErr then
		task.wait(gun:_GetFireCooldownDuration())
	end

	if thisFireSessionId == fireSessionId then
		isFiring = false
	end
end

local function setupMobile()
	connections:Add(
		"mouseDown",
		mobileCanvas.Fire.MouseButton1Down:Connect(function()
			if gun:IsPilotingControlledDrone() then
				return
			end
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
			if gun:IsPilotingControlledDrone() then
				return
			end
			setMouseDown(false)
			gun:Reload()
		end)
	)

	connections:Add(
		"aim",
		mobileCanvas.Aim.MouseButton1Up:Connect(function()
			if gun:IsPilotingControlledDrone() then
				return
			end
			gun:ToggleAim(not gun.isAiming)
		end)
	)

	connections:Add(
		"view",
		mobileCanvas.View.MouseButton1Up:Connect(function()
			if gun:IsPilotingControlledDrone() then
				return
			end
			Strafer:SetShoulderDirection(-1 * Strafer.ShoulderDirection)
		end)
	)
end

local function setupDesktop()
	connections:Add(
		"inputBegan",
		UIS.InputBegan:Connect(function(input, gp)
			local key = input.KeyCode
			local allowConsoleInput = (
				key == Enum.KeyCode.ButtonR2
				or key == Enum.KeyCode.ButtonL2
				or key == Enum.KeyCode.ButtonX
				or key == Enum.KeyCode.ButtonB
				or key == Enum.KeyCode.ButtonR3
			)
			if gp and not allowConsoleInput then
				return
			end
			if handleControlledDroneInput(input) then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				setMouseDown(true)
			elseif key == Enum.KeyCode.ButtonR2 then
				setMouseDown(true)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				gun:ToggleAim(true)
			elseif key == Enum.KeyCode.ButtonL2 then
				gun:ToggleAim(true)
			elseif key == Enum.KeyCode.R then
				gun:Reload()
			elseif key == Enum.KeyCode.ButtonX then
				gun:Reload()
			end
		end)
	)

	connections:Add(
		"inputEnd",
		UIS.InputEnded:Connect(function(input, _gp)
			if gun:IsPilotingControlledDrone() then
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					setMouseDown(false)
				elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
					setMouseDown(false)
				end
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				setMouseDown(false)
			elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
				setMouseDown(false)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				gun:ToggleAim(false)
			elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
				gun:ToggleAim(false)
			end
		end)
	)
end

local lastAutoInterval = tick()
local function setupAutoshoot()
	if gun:UseControlledDrone() then
		return
	end

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
				gun:ResetFireRateRamp()
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
				if useViewportAim() then
					aimPos, hit = getHitFromViewport()
				else
					hit = mouse.Target
					aimPos = hit and mouse.Hit.Position or nil
				end
			end

			if not hit then
				mouseDown = false
				gun:ResetFireRateRamp()
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
					gun:ResetFireRateRamp()
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

local function refreshControllerKeybinds()
	Keybinds.clear(tool.Name)

	if not gun.isEquipped or not hasController then
		return
	end

	Keybinds.addKeybind(Enum.KeyCode.ButtonR2, {
		description = "Fire",
		group = tool.Name,
	})
	Keybinds.addKeybind(Enum.KeyCode.ButtonL2, {
		description = "Aim",
		group = tool.Name,
	})
	Keybinds.addKeybind(Enum.KeyCode.ButtonX, {
		description = "Reload",
		group = tool.Name,
	})
	Keybinds.addKeybind(Enum.KeyCode.ButtonR3, {
		description = "Swap View",
		group = tool.Name,
	})
end

local function refreshControlledDroneKeybinds()
	Keybinds.clear(tool.Name)

	if hasController then
		Keybinds.addKeybind(DRONE_EXIT_GAMEPAD_KEY, {
			description = "Exit Drone",
			group = tool.Name,
		})
		Keybinds.addKeybind(DRONE_DETONATE_GAMEPAD_KEY, {
			description = "Detonate",
			group = tool.Name,
		})
	else
		Keybinds.addKeybind(DRONE_EXIT_KEY.Name, {
			description = "Exit Drone",
			group = tool.Name,
		})
		Keybinds.addKeybind(DRONE_DETONATE_KEY.Name, {
			description = "Detonate",
			group = tool.Name,
		})
	end
end

function gun:_OnControlledDroneKeybindsChanged(isActive: boolean)
	if isActive then
		refreshControlledDroneKeybinds()
	else
		refreshControllerKeybinds()
	end
end

local function syncGuidedTargeting()
	if guidedTargeting then
		guidedTargeting:Destroy(true)
		guidedTargeting = nil
	end

	if not gun.isEquipped or not gun:UseGuidedLock() then
		return
	end

	guidedTargeting = GuidedTargeting:new({
		player = LocalPlayer,
		root = gun:GetGuidedTargetRoot(),
		weaponObject = gun.object,
		firePoint = gun.firePoint,
		maxDistance = gun.settings.Caster.MaxDistance or 1500,
	})
end

local function onEquip()
	fireSessionId += 1
	connections:Add("heartbeat", RunService.Heartbeat:Connect(onHeartbeat))
	setupControlledDroneSeatExit()

	gun:Equip()
	connections:Add(
		"gamepadConnection",
		MiscUtils.watchGamepadConnection(function(connected)
			hasController = connected
			if gun:IsPilotingControlledDrone() then
				refreshControlledDroneKeybinds()
			else
				refreshControllerKeybinds()
			end
			refreshMobileCanvasVisibility()
		end)
	)
	syncGuidedTargeting()
	local autoShootMode = AUTOSHOOT_SETTINGS.Mode
	if isMobile then
		setupMobile()
		refreshMobileCanvasVisibility()
	end

	setupDesktop()

	if isMobile then
		if autoShootMode == "Mobile" then
			setupAutoshoot()
		end
	else
		if autoShootMode == "Any" then
			setupAutoshoot()
		end
	end
end

local function onUnEquip()
	fireSessionId += 1
	connections:RemoveAll()
	gun:CancelControlledDrone(true)
	gun:Unequip()
	if guidedTargeting then
		guidedTargeting:Destroy(true)
		guidedTargeting = nil
	end
	isFiring = false
	setMouseDown(false)
	if isMobile then
		mobileCanvas.Visible = false
	end
	Keybinds.clear(tool.Name)
end

-- ============== Connections =============

tool.Equipped:Connect(onEquip)
tool.Unequipped:Connect(onUnEquip)
