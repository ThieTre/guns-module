local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local AnimManager = require(Modules.Mega.Utils.AnimManager)
local ClientCaster = require(Modules.Casting.ClientCaster)
local AMS = require(Modules.AMS.Controller)
local Strafer = require(Modules.Strafer)
local ICache = require(Modules.Mega.Utils.InstanceCache)
local MiscUtils = require(Modules.Mega.Utils.Misc)
local EffectsManager = require(Modules.Mega.Utils.EffectsManager)
local PlayerUtils = require(Modules.Mega.Utils.Player)
local InstModify = require(Modules.Mega.Instances.Modify)
local ConnManager = require(Modules.Mega.Utils.ConnManager)

local LOG = Logging:new("Guns.ClientGun")
local SETTINGS = require(ReplicatedStorage.Settings.Guns)
local BACKPACK_SETTINGS = require(ReplicatedStorage.Settings.Backpack)

local LocalPlayer = Players.LocalPlayer
-- Instance ownership is cleared explicitly by _ReleaseCrosshair.
local CROSSHAIR_OWNERS = {}
local REMOTE_SETUPS = {}
local REMOTE_GENERATIONS = setmetatable({}, { __mode = "k" })

-----------------------------------------------------------
----------------------- Client Gun ------------------------
-----------------------------------------------------------

local ClientGun = setmetatable({}, { __index = ClientCaster })
ClientGun.__index = ClientGun
export type ClientGun = typeof(ClientGun)

function ClientGun:new(tool: Tool): ClientGun
	self = self ~= ClientGun and self or setmetatable({}, ClientGun)
	self.__clientcaster = ClientCaster

	self.object = tool
	self.handle = self.object:WaitForChild("Handle")
	self.lastFire = 0
	self.lastAimChange = 0
	self.nextBarrelCount = 1
	self.fireRateRampStart = nil
	self.nextFireTime = 0
	self.canAim = true
	self.isAiming = false

	-- Base table
	self.remoteFunction = self.object:WaitForChild("RemoteFunction")
	self.__clientcaster.new(self, tool)
	self.currentAmmo = self.settings.Gun.Capacity

	-- Ui
	self.ui = self.player.PlayerGui:WaitForChild("Gun")
	self.scopeUi = self.player.PlayerGui:WaitForChild("Scope")
	self.hotbar = self.player.PlayerGui.HUD.Hotbar.Tiles

	return self
end

-- =============== Cast Type Setup ==============

function ClientGun:_Setup()
	self.__clientcaster._Setup(self)

	PlayerUtils.onDeath(self.humanoid, function()
		self:Unequip()
	end)

	self:_SetupAnimations()
	self:_SetupEffects()
	self:_SetupConnections()

	self.losPart = self.character:WaitForChild("Head")
end

function ClientGun:_SetupAnimations()
	self.animManager = AnimManager:new(self.object.Animations:GetChildren())

	-- Torso locking with running
	self.humanoid.Running:Connect(function(speed: number)
		if self.isEquipped then
			if speed <= 0 then
				-- May need to unlock torso
				local ts = 0.3
				task.wait(ts)
				if AMS.currentSpeed == speed and speed <= 0 then
					self:_RequestTorsoLock(false)
				end
			else
				if self.isAiming then
					self:_RequestTorsoLock(true)
				end
			end
		end
	end)

	-- Lower gun when sprinting
	AMS.config:Watch("Sprinting", function(isSprinting: boolean)
		if not self.isEquipped then
			return
		end

		local speed = self.humanoid.RootPart.AssemblyLinearVelocity.Magnitude

		if isSprinting and speed > 0 then -- TODO: added in speed, does it work?
			self.animManager["Hold"]:Stop()
			self.animManager["Sprint"]:Play()
			self:_RequestTorsoLock(false, true)
		else
			self:_Hold()
			self.animManager["Sprint"]:Stop()
		end
	end)

	-- Adjust animation speed
	repeat
		task.wait()
	until self.animManager["Reload"].Length > 0
	repeat
		task.wait()
	until self.animManager["Equip"].Length > 0
	local reloadTime = self.settings.Gun.ReloadTime
	self.reloadAnimSpeed = self.animManager["Reload"].Length / reloadTime
end

function ClientGun:_SetupEffects()
	-- Firing
	local gun = self.object
	local handle = gun.Handle
	if handle:FindFirstChild("Fire") then
		self.fireSoundCache = ICache:new(handle.Fire, { parent = handle })
	end
	self.effectsManager = EffectsManager:new(gun:GetDescendants())
end

function ClientGun:_SetupConnections()
	self.remoteFunction.OnClientInvoke = function(event: string)
		if event == "Reload" then
			task.spawn(self.Reload, self, true)
		end
	end

	local remoteEvent: RemoteEvent = self.object:WaitForChild("RemoteEvent")
	remoteEvent.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or payload.Type ~= "CastRejected" then
			return
		end

		self:CancelProjectileCastById(payload.Id)
	end)
end

-- =============== Firing ==============

function ClientGun:Fire(
	pos: Vector3,
	kwargs: {
		ignoreFireCheck: boolean?,
	}?
): boolean
	local fired = self:_FireFunctionality(pos, kwargs)
	if not fired then
		return false
	end
	self:_FireEffects()
	self:_FireAnimations()
	self:_FireInterface()

	return true
end

function ClientGun:_UsesBurstFireRate(): boolean
	local fireMode = self.settings.Gun.FireMode
	return fireMode == "Burst" or fireMode == "AutoBurst"
end

function ClientGun:_GetFireRateRampSettings(): {}?
	local rampSettings = self.settings.Gun.FireRateRamp
	if not rampSettings then
		return nil
	end

	local duration = rampSettings.Duration or 0
	local targetRate = self.settings.Gun.FireRate
	local startRatio = rampSettings.StartRatio

	if duration <= 0 or not startRatio or startRatio <= 0 or startRatio >= 1 then
		return nil
	end

	return {
		Duration = duration,
		StartRate = targetRate * startRatio,
	}
end

function ClientGun:_GetBurstSize(): number
	return self.settings.Gun.BurstSize or 1
end

function ClientGun:_GetBurstDelay(): number
	return self.settings.Gun.BurstDelay or self.settings.BurstDelay or 0
end

function ClientGun:_GetBaseFireCooldownDuration(): number
	return 1 / self.settings.Gun.FireRate
end

function ClientGun:_GetHeldFireDuration(): number
	if not self.fireRateRampStart then
		return 0
	end

	return tick() - self.fireRateRampStart
end

function ClientGun:_GetCurrentFireRate(): number
	local rampSettings = self:_GetFireRateRampSettings()
	if not rampSettings or not self.fireRateRampStart then
		return self.settings.Gun.FireRate
	end

	local alpha = math.clamp(self:_GetHeldFireDuration() / rampSettings.Duration, 0, 1)
	return rampSettings.StartRate
		+ ((self.settings.Gun.FireRate - rampSettings.StartRate) * alpha)
end

function ClientGun:_GetFireCooldownDuration(): number
	return 1 / self:_GetCurrentFireRate()
end

function ClientGun:_LockFireCooldown(duration: number?)
	duration = duration or 0
	self.nextFireTime = math.max(self.nextFireTime or 0, tick() + duration)
end

function ClientGun:_GetShotIntervalDuration(): number
	if self:_UsesBurstFireRate() and self:_GetBurstSize() > 1 then
		return self:_GetBurstDelay()
	end

	return self:_GetFireCooldownDuration()
end

function ClientGun:_GetBurstCycleDuration(): number
	local burstSize = self:_GetBurstSize()
	local cycleDuration = self:_GetFireCooldownDuration()

	if burstSize > 1 then
		cycleDuration += (burstSize - 1) * self:_GetBurstDelay()
	end

	return cycleDuration
end

function ClientGun:ResetFireRateRamp()
	self.fireRateRampStart = nil
end

function ClientGun:_FireFunctionality(
	pos,
	kwargs: {
		ignoreFireCheck: boolean?,
		includeEffects: boolean?,
	}?
): boolean
	kwargs = kwargs or {}

	if self.currentAmmo < 1 then
		self:Reload()
		return false
	end
	if not kwargs.ignoreFireCheck and not self:_CanFire() then
		return false
	end
	if not self:PrepareProjectileLaunch() then
		return false
	end

	local guidedTargetVehicle = nil
	if self:UseGuidedLock() then
		guidedTargetVehicle = self:GetGuidedTargetVehicle()
		if not guidedTargetVehicle then
			return false
		end
	end

	-- Adjust spread
	local spreadAdj = 1
	if self.isFullyAimed then
		spreadAdj *= self.settings.Gun.AimSpreadAdj or SETTINGS.DefaultAimSpreadAdj
	end
	if AMS.isCrouching then
		spreadAdj *= self.settings.Gun.CrouchSpreadAdj or SETTINGS.DefaultCrouchSpreadAdj
	end

	local function fire()
		for _ = 1, self.settings.Gun.BulletsPerShot or 1 do
			if self.settings.Gun.LockProjectileDirection then
				local barrelForward = self.firePoint.WorldCFrame.LookVector
				local posDirection = (pos - self.firePoint.WorldPosition).Unit
				local dot = barrelForward:Dot(posDirection)
				local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))

				if angle > 5 then
					local distance = (self.firePoint.WorldPosition - pos).Magnitude
					if distance > 10 then
						pos = (self.firePoint.WorldPosition + barrelForward * 10000)
					end
				end
			end
			self:Cast(pos, spreadAdj, {
				guidedTarget = guidedTargetVehicle,
			})
		end
		if kwargs.includeEffects then
			self:_FireEffects()
		end
	end

	-- Firing
	local thisFire = tick()
	if not self.fireRateRampStart then
		self.fireRateRampStart = thisFire
	end
	self.lastFire = thisFire
	if not kwargs.ignoreFireCheck and not self:_UsesBurstFireRate() then
		self:_LockFireCooldown(self:_GetFireCooldownDuration())
	end
	self.currentAmmo -= 1
	if self.fireDelay then
		task.delay(self.fireDelay, fire)
	else
		fire()
	end

	-- Recoil
	if not self.isMobile and not SETTINGS.RecoilDisabled then
		Strafer.TargetVertAngleOffset += self.settings.Gun.VerticalRecoil
		task.delay(math.clamp(self:_GetShotIntervalDuration() * 1.5, 0, 0.5), function()
			if self.lastFire == thisFire then
				Strafer.TargetVertAngleOffset = 0
			end
		end)
	end

	if self.currentAmmo < 1 then
		task.spawn(function()
			self:Reload(true)
		end)
	end

	return true
end

function ClientGun:_FireAnimations()
	-- Torso and AMS control
	self:_RequestTorsoLock(true)
	AMS:EndSprint()
	if self.animManager["Sprint"].IsPlaying then
		self.animManager["Sprint"].Ended:Wait()
	end

	-- Fire animations
	if self.animManager["Bolt"] and self.currentAmmo > 0 then
		task.delay(self:_GetShotIntervalDuration() * 0.3, function()
			self.animManager["Bolt"]:Play()
			self.effectsManager:Run("Bolt")
		end)
	end
	self.animManager["Shoot"]:Play()
end

function ClientGun:_FireInterface()
	self:_RefreshHotbarState()
end

function ClientGun:_RefreshHotbarState()
	local slot = self:_GetSlot()
	local tile = self.hotbar[slot]
	if not tile then
		return
	end

	tile.Count.Text = math.floor(self.currentAmmo)

	local blocked = tile:FindFirstChild("Blocked")
	if blocked then
		blocked.Visible = self._activeProjectileLimitBlocked == true
	end

	if self._activeProjectileLimitBlocked then
		tile.Count.TextColor3 = Color3.new(1, 0.760784, 0.329412)
	elseif self.currentAmmo / self.settings.Gun.Capacity <= 0.15 then
		tile.Count.TextColor3 = Color3.new(1, 0.376471, 0.376471)
	else
		tile.Count.TextColor3 = Color3.new(1, 1, 1)
	end
end

function ClientGun:SetActiveProjectileLimitBlocked(isBlocked: boolean)
	if self._activeProjectileLimitBlocked == isBlocked then
		return
	end

	self._activeProjectileLimitBlocked = isBlocked
	self:_RefreshHotbarState()
end

function ClientGun:_FireEffects()
	if self.fireSoundCache then
		local sound = self.fireSoundCache:Get()
		sound:Play()
		sound.Ended:Once(function()
			self.fireSoundCache:Return(sound)
		end)
	end

	self.effectsManager:RunAll("Fire")

	if self.settings.Gun.BarrelCount then
		self.effectsManager:RunAll("FireBarrel" .. self.nextBarrelCount)
		self.nextBarrelCount += 1
		if self.nextBarrelCount > self.settings.Gun.BarrelCount then
			self.nextBarrelCount = 1
		end
	end
end

function ClientGun:_CanFire()
	local factors = {
		tick() >= (self.nextFireTime or 0),
		self.object.Parent == self.character,
		self.currentAmmo > 0,
		not self.isReloading,
		self.humanoid.Health > 0,
		not LocalPlayer:GetAttribute("ControlsLockEnabled"),
	}
	return not table.find(factors, false)
end

-- =============== Reloading ==============

function ClientGun:Reload(force: boolean?)
	if self:IsPilotingControlledDrone() and not force then
		return false
	end

	local canReload = force
		or (not self.isReloading and self.currentAmmo ~= self.settings.Gun.Capacity)
	if not canReload then
		return false
	end

	self:ResetFireRateRamp()
	self:_ReloadEffects()
	self:_ReloadFunctionality()

	self:_RefreshHotbarState()
end

function ClientGun:_ReloadFunctionality()
	if not self.settings.Gun.AllowAimingOnReload then
		self:ToggleAim(false)
		self.canAim = false
	end

	self.isReloading = true
	self.object:SetAttribute("IsReloading", true)
	self:_RefreshReloadIndicator()
	local newAmmo = self.remoteFunction:InvokeServer("Reload", true)
	self.isReloading = false
	self.object:SetAttribute("IsReloading", false)
	self:_RefreshReloadIndicator()

	self.canAim = true
	if newAmmo == self.currentAmmo then
		return false
	end
	self.currentAmmo = newAmmo or self.currentAmmo

	return true
end

function ClientGun:_ReloadEffects()
	-- Animations
	self.animManager["Reload"]:Play(1, 1, self.reloadAnimSpeed)
end

-- =============== Crosshair ==============

local CHAT_VISIBILITY_POLL_INTERVAL = 0.25
local chatWindowConfig = TextChatService.ChatWindowConfiguration
local chatInputConfig = TextChatService.ChatInputBarConfiguration
local isChatActive = true

local function isPointerInBounds(pointer: Vector2, position: Vector2, size: Vector2): boolean
	return pointer.X >= position.X
		and pointer.Y >= position.Y
		and pointer.X < position.X + size.X
		and pointer.Y < position.Y + size.Y
end

local function shouldShowCoreUICursor(pointer: Vector2): boolean
	if not UIS.MouseEnabled or UIS.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
		return false
	end
	if GuiService.MenuIsOpen or chatInputConfig.IsFocused then
		return true
	end
	if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
		return false
	end

	local camera = workspace.CurrentCamera
	if not camera or not isPointerInBounds(pointer, Vector2.zero, camera.ViewportSize) then
		return false
	end
	local topLeftInset = GuiService:GetGuiInset()
	-- TopbarInset describes free space; its bottom edge also covers Roblox's buttons.
	if pointer.Y < math.max(topLeftInset.Y, GuiService.TopbarInset.Max.Y) then
		return true
	end
	if not isChatActive or not StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Chat) then
		return false
	end
	if
		chatWindowConfig.Enabled
		and isPointerInBounds(pointer, chatWindowConfig.AbsolutePosition, chatWindowConfig.AbsoluteSize)
	then
		return true
	end
	return chatInputConfig.Enabled
		and isPointerInBounds(pointer, chatInputConfig.AbsolutePosition, chatInputConfig.AbsoluteSize)
end

-- GetCore may yield; keep visibility sampling outside the crosshair render callback.
if RunService:IsClient() then
	task.spawn(function()
		while true do
			if UIS.MouseEnabled then
				local success, res = pcall(StarterGui.GetCore, StarterGui, "ChatActive")
				if success then
					isChatActive = res ~= false
				end
			end
			task.wait(CHAT_VISIBILITY_POLL_INTERVAL)
		end
	end)
end

function ClientGun:_ClaimCrosshair()
	if not self.isEquipped or self.childOf or (self.IsAbility and self:IsAbility()) then
		return
	end

	local dot = self.ui.Dot
	local previousOwner = CROSSHAIR_OWNERS[dot]
	if previousOwner == self then
		self:_RefreshCrosshair()
		self:_RefreshReloadIndicator()
		return
	end
	if previousOwner then
		previousOwner:_ReleaseCrosshair()
	end

	CROSSHAIR_OWNERS[dot] = self
	self._crosshairDot = dot
	self._crosshairPosition = dot.Position
	self._crosshairAnchorPoint = dot.AnchorPoint
	-- Strafer owns cursor hiding while enabled; its disabled state shows it again.
	self._crosshairMouseIconEnabled = UIS.MouseIconEnabled or Strafer.IsEnabled == true
	self._crosshairConnections = ConnManager:new()
	local indicator = dot:FindFirstChild("Reload")
	self._reloadIndicator = indicator

	local function release()
		self:_ReleaseCrosshair()
	end
	self._crosshairConnections:Add("Weapon", self.object.Destroying:Connect(release))
	self._crosshairConnections:Add("Dot", dot.Destroying:Connect(release))
	self._crosshairConnections:Add("Death", self.humanoid.Died:Connect(release))
	self._crosshairConnections:Add("Strafer", Strafer.StateChanged:Connect(function()
		self:_RefreshCrosshair()
	end))
	if indicator then
		self._reloadIndicatorRotation = indicator.Rotation
		self._crosshairConnections:Add("Indicator", indicator.Destroying:Connect(function()
			if self._reloadIndicator ~= indicator then
				return
			end
			self:_StopReloadIndicator()
			self._reloadIndicator = nil
			self._reloadIndicatorRotation = nil
		end))
	end
	self:_RefreshCrosshair()
	self:_RefreshReloadIndicator()
end

function ClientGun:_UsesMouseCrosshair(): boolean
	return false
end

function ClientGun:_ShouldShowCrosshair(): boolean
	return not (self.isAiming and self.settings.Gun.Scope)
end

function ClientGun:_UpdateCrosshairPosition(position: Vector2?)
	local dot = self._crosshairDot
	if
		not dot
		or CROSSHAIR_OWNERS[dot] ~= self
		or Strafer.IsPauseRequested
		or Strafer.IsPaused
	then
		return
	end

	position = position or UIS:GetMouseLocation()
	if not self.ui.IgnoreGuiInset then
		local topLeftInset = GuiService:GetGuiInset()
		position -= topLeftInset
	end
	dot.Position = UDim2.fromOffset(position.X, position.Y)
end

function ClientGun:_RefreshCrosshair()
	local dot = self._crosshairDot
	if not dot or CROSSHAIR_OWNERS[dot] ~= self then
		return
	end

	local isPilotingDrone = self._controlledDroneCameraOverrideActive == true
		or self:IsPilotingControlledDrone()
	local isPaused = Strafer.IsPauseRequested or Strafer.IsPaused
	local isStraferActive = Strafer.IsEnabled and not isPaused
	local useMouse = not isPilotingDrone and not isPaused and self:_UsesMouseCrosshair()
	local mousePosition = if useMouse then UIS:GetMouseLocation() else nil
	local showCoreUICursor = mousePosition ~= nil
		and not Strafer.IsEnabled
		and shouldShowCoreUICursor(mousePosition)
	dot.Visible = not isPilotingDrone
		and not isPaused
		and not showCoreUICursor
		and (isStraferActive or useMouse)
		and self:_ShouldShowCrosshair()
	if useMouse then
		if not self._crosshairFollowsMouse then
			dot.AnchorPoint = Vector2.new(0.5, 0.5)
			self._crosshairConnections:Add(
				"Render",
				RunService.RenderStepped:Connect(function()
					self:_RefreshCrosshair()
				end)
			)
			self._crosshairFollowsMouse = true
		end
		if not showCoreUICursor then
			self:_UpdateCrosshairPosition(mousePosition)
		end
	else
		self._crosshairConnections:Remove("Render")
		self._crosshairFollowsMouse = false
		dot.Position = self._crosshairPosition
		dot.AnchorPoint = self._crosshairAnchorPoint
	end
	if isPaused then
		UIS.MouseIconEnabled = true
	elseif isPilotingDrone then
		UIS.MouseIconEnabled = self._crosshairMouseIconEnabled and not Strafer.IsEnabled
	elseif useMouse then
		UIS.MouseIconEnabled = showCoreUICursor
	else
		UIS.MouseIconEnabled = not isStraferActive and not useMouse
	end
end

function ClientGun:_ReleaseCrosshair()
	local dot = self._crosshairDot
	-- A delayed reload or unequip must not change the replacement owner's UI.
	if not dot or CROSSHAIR_OWNERS[dot] ~= self then
		return
	end

	self:_StopReloadIndicator()
	self._crosshairConnections:RemoveAll()
	dot.Visible = false
	dot.Position = self._crosshairPosition
	dot.AnchorPoint = self._crosshairAnchorPoint
	UIS.MouseIconEnabled = Strafer.IsPauseRequested
		or Strafer.IsPaused
		or (self._crosshairMouseIconEnabled and not Strafer.IsEnabled)
	CROSSHAIR_OWNERS[dot] = nil
	self._crosshairConnections = nil
	self._crosshairDot = nil
	self._crosshairPosition = nil
	self._crosshairAnchorPoint = nil
	self._crosshairMouseIconEnabled = nil
	self._crosshairFollowsMouse = nil
	self._reloadIndicator = nil
	self._reloadIndicatorRotation = nil
end

function ClientGun:_RefreshReloadIndicator()
	local dot = self._crosshairDot
	if not dot or CROSSHAIR_OWNERS[dot] ~= self or not self._reloadIndicator then
		return
	end

	local indicator = self._reloadIndicator
	local isReloading = self.isEquipped and self.isReloading == true
	indicator.Visible = isReloading
	if isReloading then
		if not self._reloadIndicatorTween then
			self._reloadDotTransparency = dot.ImageTransparency
			dot.ImageTransparency = 1
			local tween = TweenService:Create(
				indicator,
				TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
				{ Rotation = self._reloadIndicatorRotation + 360 }
			)
			self._reloadIndicatorTween = tween
			tween:Play()
		end
		return
	end

	self:_StopReloadIndicator()
end

function ClientGun:_StopReloadIndicator()
	if self._reloadIndicatorTween then
		self._reloadIndicatorTween:Cancel()
		self._reloadIndicatorTween:Destroy()
		self._reloadIndicatorTween = nil
	end
	if self._reloadIndicator then
		self._reloadIndicator.Visible = false
		self._reloadIndicator.Rotation = self._reloadIndicatorRotation
	end
	if self._reloadDotTransparency ~= nil then
		self._crosshairDot.ImageTransparency = self._reloadDotTransparency
		self._reloadDotTransparency = nil
	end
end

-- =============== Aiming ==============

function ClientGun:ToggleAim(enabled: boolean)
	if self:IsPilotingControlledDrone() then
		return
	end

	if not self.canAim or self.isAiming == enabled then
		return
	end
	AMS:EndSprint()
	local targetFOV = nil
	local tweenInfo = TweenInfo.new(self.settings.Gun.AimSpeed, Enum.EasingStyle.Linear)
	local scopeSettings = self.settings.Gun.Scope

	if scopeSettings then
		scopeSettings.AimSpeed = scopeSettings.AimSpeed or self.settings.Gun.AimSpeed
	end

	self.isAiming = enabled

	local thisAim = tick()
	self.lastAimChange = thisAim

	if enabled then
		self:_RequestTorsoLock(true)
		local defaultSettings = Strafer.CameraSettings.DefaultShoulder
		local zoomSettings = Strafer.CameraSettings.ZoomedShoulder
		if math.abs(defaultSettings.Offset.X) < 0.1 then
			defaultSettings.Offset =
				Vector3.new(2.25, defaultSettings.Offset.Y, defaultSettings.Offset.Z)
		end
		zoomSettings.CanSwitchShoulder = true
		if math.abs(zoomSettings.Offset.X) < 0.1 then
			zoomSettings.Offset =
				Vector3.new(1.5, zoomSettings.Offset.Y, zoomSettings.Offset.Z)
		end
		local mobileAimAdj = 1
		if self.isMobile and not self.settings.Gun.Scope then
			mobileAimAdj = SETTINGS.MobileAimMult
		end
		targetFOV = SETTINGS.DefaultFOV
			* (1 / self.settings.Gun.AimFOVMult)
			* mobileAimAdj
		zoomSettings.FieldOfView = targetFOV

		Strafer:SetActiveCameraSettings("ZoomedShoulder")
		self.effectsManager:Run("ZoomIn")
		if scopeSettings then
			self:_UpdateScopeUI(scopeSettings, true)
			local gunLength = (
				self.settings.Caster.FirePoint.WorldCFrame.Position
				- self.object.Handle.position
			).Magnitude * 1.5
			local crouchAdj = AMS.isCrouching and 0 or 1
			-- Setup camera
			zoomSettings.Offset = Vector3.new(0.7, 1.2 * crouchAdj, -gunLength - 1)
		else
			zoomSettings.Offset = Strafer.CameraSettings.DefaultShoulder.Offset
		end
		self.humanoid.WalkSpeed *= self.settings.Gun.AimWalkSpeedAdj
	else
		self.isFullyAimed = false
		self:_RequestTorsoLock(false)
		Strafer:SetActiveCameraSettings("DefaultShoulder")
		targetFOV = SETTINGS.DefaultFOV
		self.effectsManager:Run("ZoomOut")
		-- Return camera back to normal
		if scopeSettings then
			self:_UpdateScopeUI(scopeSettings, false)
		end
		self.humanoid.WalkSpeed /= self.settings.Gun.AimWalkSpeedAdj
	end

	self:_RefreshCrosshair()
	local tween = TweenService:Create(
		workspace.CurrentCamera,
		tweenInfo,
		{ FieldOfView = targetFOV }
	)
	tween:Play()

	-- Adjust aim spread
	if enabled then
		tween.Completed:Connect(function()
			if thisAim ~= self.lastAimChange then
				return
			end
			self.isFullyAimed = true
		end)
	end
end

function ClientGun:_OnControlledDroneControlAcquired(_cast: {})
	if self._controlledDroneCameraOverrideActive then
		return
	end

	self._controlledDroneCameraOverrideActive = true

	if self.isAiming then
		self:ToggleAim(false)
	end

	if Strafer.IsEnabled then
		Strafer:SetEnabled(false)
	end

	if self._OnControlledDroneKeybindsChanged then
		self:_OnControlledDroneKeybindsChanged(true)
	end
	self:_RefreshCrosshair()
end

function ClientGun:_OnControlledDroneControlReleased(_cast: {}, isTransfer: boolean)
	if isTransfer or not self._controlledDroneCameraOverrideActive then
		return
	end

	self._controlledDroneCameraOverrideActive = false
	self.isAiming = false
	Strafer:SetEnabled(false)
	-- Strafer can restore the FOV it saved before drone control began. Reset it
	-- before re-enabling Strafer so that value cannot carry into the next drone.
	workspace.CurrentCamera.FieldOfView = SETTINGS.DefaultFOV
	UIS.MouseBehavior = Enum.MouseBehavior.Default
	UIS.MouseIconEnabled = true

	if self._OnControlledDroneKeybindsChanged then
		self:_OnControlledDroneKeybindsChanged(false)
	end

	self:_ApplyEquippedStraferState()
	self:_RefreshCrosshair()
end

function ClientGun:_UpdateScopeUI(scopeSettings: {}, enabled: boolean)
	local scope = self.scopeUi.Scope
	self.defaultScopeSize = self.defaultScopeSize or scope.Size
	self.defaultReticleSize = self.defaultReticleSize or scope.Reticle.Size
	scope.Reticle.Image = scopeSettings.ReticleImage or ""
	scope.Left.BackgroundColor3 = scopeSettings.BackgroundColor or Color3.new()
	scope.Right.BackgroundColor3 = scopeSettings.BackgroundColor or Color3.new()
	scope.Top.BackgroundColor3 = scopeSettings.BackgroundColor or Color3.new()
	scope.Bottom.BackgroundColor3 = scopeSettings.BackgroundColor or Color3.new()

	local aimSpeed = scopeSettings.AimSpeed
	local backgroundTransp, reticleTransp
	if enabled then
		backgroundTransp = scopeSettings.BackgroundTransparency or 1
		reticleTransp = scopeSettings.ReticleTransparency or 0
		aimSpeed *= 2
	else
		backgroundTransp = 1
		reticleTransp = 1
	end

	local tweenInfo = (
		TweenInfo.new(aimSpeed, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	)

	local tweens = {}
	for _, frame in { scope.Left, scope.Right, scope.Top, scope.Bottom } do
		local tween = TweenService:Create(
			frame,
			tweenInfo,
			{ BackgroundTransparency = backgroundTransp }
		)
		table.insert(tweens, tween)
	end
	local tween = TweenService:Create(
		scope.Reticle,
		tweenInfo,
		{ ImageTransparency = reticleTransp }
	)
	table.insert(tweens, tween)

	scope.Size = self.defaultScopeSize
	if scopeSettings.ReticleScale and enabled then
		scope.Reticle.Size = scopeSettings.ReticleScale
	else
		scope.Reticle.Size = self.defaultReticleSize
	end

	for _, tween in tweens do
		tween:Play()
	end

	if scopeSettings.IncludeMetadata then
		scope.FirePoint.Value = enabled and self.firePoint or nil
	end

	return tweens
end

-- =============== Equip/Unequip ==============

function ClientGun:_ApplyEquippedStraferState(force: boolean?)
	if not force and not self.isEquipped then
		return
	end

	local defaultSettings = Strafer.CameraSettings.DefaultShoulder
	defaultSettings.CanSwitchShoulder = true
	if math.abs(defaultSettings.Offset.X) < 0.1 then
		defaultSettings.Offset =
			Vector3.new(2.25, defaultSettings.Offset.Y, defaultSettings.Offset.Z)
	end
	Strafer:SetActiveCameraSettings("DefaultShoulder")
	Strafer.Target = self.hrp
	Strafer:SetEnabled(true)
end

function ClientGun:Equip()
	if self.humanoid.sit then
		return
	end

	self.object:SetAttribute("IsEquipped", true)

	self:_ApplyEquippedStraferState(true)

	self:_RequestTorsoLock(false)

	-- Ui
	self:_RefreshHotbarState()

	-- Equip
	self.isEquipped = self.object.Parent ~= self.player.Backpack
	self:_ClaimCrosshair()
	if self.isEquipped then
		self.humanoid.WalkSpeed *= self.settings.Gun.WalkspeedAdj
		self:_Hold()
	end

	self.effectsManager:RunAll("Equip")
end

function ClientGun:Unequip()
	self:_ReleaseCrosshair()
	if not self.isEquipped then
		return
	end
	self:ResetFireRateRamp()
	self:ToggleAim(false)
	Strafer:SetEnabled(false)
	self.humanoid.WalkSpeed /= self.settings.Gun.WalkspeedAdj
	self.animManager:StopAll()
	self.isEquipped = false
	self.object:SetAttribute("IsEquipped", false)
	self.effectsManager:RunAll("Unequip")
end

-- =============== Misc ==============

function ClientGun:_GetSlot()
	return self.object:GetAttribute("CurrentSlot")
end

function ClientGun:_Hold()
	if self.isEquipped then
		self.animManager["Hold"]:Play(0.1, nil, 1.6 * (self.humanoid.WalkSpeed / 16))
	end
end

--[[
	Lock the torso to minimize weapon sway if necessary
]]
function ClientGun:_RequestTorsoLock(enabled: boolean, ignoreHold: boolean?)
	local isMoving = self.humanoid.RootPart.AssemblyLinearVelocity.Magnitude > 1
	local isSprinting, isCrouching = AMS.isSprinting, AMS.isCrouching
	if enabled and not isCrouching and AMS.currentSpeed > 0 then
		self.animManager["IdleHold"]:Stop()
		self.animManager:Assign("Hold", self.animManager["WalkHold"])
	elseif not (self.isAiming and (AMS.currentSpeed > 0 or isMoving)) then
		self.animManager["WalkHold"]:Stop(0.5)
		self.animManager:Assign("Hold", self.animManager["IdleHold"])
	end
	if not ignoreHold then
		self:_Hold()
	end
end

function ClientGun:_SetHiddenParts(visible: boolean)
	for _, p in self.object.Model:GetChildren() do
		if not p:IsA("BasePart") or not p:GetAttribute("HideOnReload") then
			continue
		end
		if visible then
			p.Transparency = p:GetAttribute("_BaseTransparency") or 0
		else
			if p.Transparency ~= 0 and not p:GetAttribute("_BaseTransparency") then
				p:SetAttribute("_BaseTransparency", p.Transparency)
			end
			p.Transparency = 1
		end
	end
end

-- =============== Static ==============
--[[
	Static function to onboard all clients to
	a gun. Most likely will be called multiple
	times if streaming is enabled.

]]
function ClientGun._setupClient(gun: Tool)
	ClientGun._setupRemotes(gun)
	ClientGun._setupWelding(gun)
end

function ClientGun._cleanupRemotes(gun: Tool | Model)
	REMOTE_GENERATIONS[gun] = (REMOTE_GENERATIONS[gun] or 0) + 1
	local state = REMOTE_SETUPS[gun]
	if not state then
		return
	end
	REMOTE_SETUPS[gun] = nil
	state.connections:RemoveAll()
	if state.effectsManager then
		state.effectsManager:Destroy()
	end
	for thread in state.collector.Threads do
		if coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
			task.cancel(thread)
		end
	end
	for _, tween in state.collector.Tweens do
		tween:Cancel()
	end
	for effect in state.effects do
		if effect:IsA("Sound") then
			effect:Stop()
		elseif effect:IsA("ParticleEmitter") then
			EffectsManager.Emitter.EmitDisable(effect)
		elseif effect:IsA("Light") then
			EffectsManager.Light.StopFlashing(effect)
		end
	end
	local cache = state.soundCache
	if cache then
		for _, sound in cache.open do
			sound:Destroy()
		end
		for _, sound in cache.inUse do
			sound:Destroy()
		end
		cache.template:Destroy()
	end
end

-- Returns true once ready. Repeated calls reuse the listener and cache;
-- missing streamed children return false without yielding for those children.
function ClientGun._setupRemotes(gun: Tool | Model): boolean
	if not gun:IsDescendantOf(game) then
		return false
	end
	local state = REMOTE_SETUPS[gun]
	if state then
		if state.ready then
			return true
		elseif state.initializing then
			return false
		end
	else
		state = { connections = ConnManager:new(), effects = {} }
		state.collector = {
			Threads = {},
			Tweens = {},
			OnError = function(err)
				LOG:Warning("Remote firing effect failed: %s", tostring(err))
			end,
			AddEffect = function(_, effect)
				state.effects[effect] = true
			end,
		}
		REMOTE_SETUPS[gun] = state
		local function descendantsChanged(instance)
			if REMOTE_SETUPS[gun] ~= state then
				return
			end
			-- The cache owns its sound clones, including their descendants.
			local ancestor = instance
			while ancestor and ancestor ~= gun do
				if ancestor:GetAttribute("_RemoteFireCache") then
					return
				end
				ancestor = ancestor.Parent
			end
			if not (instance:IsA("BasePart") or instance:IsA("Attachment")
				or instance:IsA("Sound") or instance:IsA("ParticleEmitter")
				or instance:IsA("Light") or instance:IsA("RemoteEvent")
				or instance.Name == "Settings" or instance:IsA("EqualizerSoundEffect")
				or instance:IsA("Animator")) then
				return
			end
			ClientGun._cleanupRemotes(gun)
			local generation = REMOTE_GENERATIONS[gun]
			task.defer(function()
				if REMOTE_GENERATIONS[gun] == generation then
					ClientGun._setupRemotes(gun)
				end
			end)
		end
		state.connections:Add("Added", gun.DescendantAdded:Connect(descendantsChanged))
		state.connections:Add("Removing", gun.DescendantRemoving:Connect(descendantsChanged))
		state.connections:Add("Ancestry", gun.AncestryChanged:Connect(function()
			if REMOTE_SETUPS[gun] == state and not gun:IsDescendantOf(game) then
				ClientGun._cleanupRemotes(gun)
			end
		end))
		state.connections:Add("Destroying", gun.Destroying:Connect(function()
			if REMOTE_SETUPS[gun] == state then
				ClientGun._cleanupRemotes(gun)
			end
		end))
	end
	local remoteEvent = gun:FindFirstChild("RemoteEvent")
	local handle = gun:FindFirstChild("Handle")
	local settingsModule = gun:FindFirstChild("Settings")
	local firePoint = handle and handle:FindFirstChild("FirePoint")
	if not remoteEvent or not handle or not settingsModule or not firePoint then
		return false
	end
	local fireTemplate = handle:FindFirstChild("Fire")
	if fireTemplate and not fireTemplate:FindFirstChild("EqualizerSoundEffect") then
		return false
	end
	state.initializing = true
	local success, res = pcall(require, settingsModule)
	if REMOTE_SETUPS[gun] ~= state then
		return false
	end
	if not success then
		ClientGun._cleanupRemotes(gun)
		error(res)
	end
	local gunSettings = res
	local nextBarrelCount = 1
	local barrelCount = gunSettings.Gun.BarrelCount
	local inheritParentSpeed = gunSettings.Caster.InheritParentSpeed
	local projecileSpeed = gunSettings.Caster.ProjectileSpeed

	-- Register ownership before animation marker lookups can yield.
	local effectsManager = EffectsManager:new()
	state.effectsManager = effectsManager
	effectsManager:new(gun:GetDescendants())
	if REMOTE_SETUPS[gun] ~= state then
		return false
	end
	effectsManager:UpdateGroup("Fire", { "Emitter" })

	-- Setup sound cache
	local soundCache = nil
	if fireTemplate then
		-- InstanceCache takes ownership of its template; preserve the authored sound.
		local cacheTemplate = fireTemplate:Clone()
		cacheTemplate:SetAttribute("_RemoteFireCache", true)
		soundCache = ICache:new(cacheTemplate, { parent = handle })
		state.soundCache = soundCache
	end

	local emitterAttach = firePoint:FindFirstChild("EmitterAttachment")
	local emitter: ParticleEmitter = emitterAttach and emitterAttach:FindFirstChild("Emitter")
	state.connections:Add("Fire", remoteEvent.OnClientEvent:Connect(function(castDistance)
		if REMOTE_SETUPS[gun] ~= state then
			return
		end
		if typeof(castDistance) == "table" then
			return
		end

		if emitter then
			if castDistance then
				emitter.Lifetime = NumberRange.new(castDistance / emitter.Speed.Max)
			else
				emitter.Lifetime = NumberRange.new(2)
			end
			if inheritParentSpeed then
				local inherited = handle.AssemblyLinearVelocity.Magnitude
				emitter.Speed = NumberRange.new(projecileSpeed * inherited)
			end
		end
		if soundCache then
			-- Configure and play sound
			local sound: Sound? = nil
			local success, err = pcall(function()
				local character = LocalPlayer.Character
				local hrp = character and character:FindFirstChild("HumanoidRootPart")
				if not hrp then
					return
				end
				local distance = (firePoint.WorldPosition - hrp.Position).Magnitude
				if distance > fireTemplate.RollOffMaxDistance then
					return
				end
				sound = soundCache:Get()
				local equalizer = sound.EqualizerSoundEffect
				if distance > SETTINGS.MuffleStartDistance then
					equalizer.Enabled = true
					local delta = distance - SETTINGS.MuffleStartDistance
					local muffleAdj = math.clamp(
						delta / SETTINGS.MaxMuffleDistance,
						0,
						1
					) * -80
					equalizer.HighGain = muffleAdj
					equalizer.MidGain = muffleAdj
					equalizer.LowGain = -muffleAdj / 6
				else
					equalizer.Enabled = false
				end
				sound:Play()
			end)

			if not success then
				if sound then
					soundCache:Return(sound)
				end
				LOG:Warning("Failed to play firing sound: %s", err)
			elseif sound then
				state.connections:Add(sound, sound.Ended:Once(function()
					state.connections:Remove(sound)
					if REMOTE_SETUPS[gun] == state then
						soundCache:Return(sound)
					end
				end))
			end
		end

		-- Run other effects
		for i = #state.collector.Tweens, 1, -1 do
			local playbackState = state.collector.Tweens[i].PlaybackState
			if playbackState == Enum.PlaybackState.Completed or playbackState == Enum.PlaybackState.Cancelled then
				table.remove(state.collector.Tweens, i)
			end
		end
		effectsManager:RunAll("Fire", state.collector)

		if barrelCount then
			effectsManager:RunAll("FireBarrel" .. nextBarrelCount, state.collector)
			nextBarrelCount += 1
			if nextBarrelCount > barrelCount then
				nextBarrelCount = 1
			end
		end
	end))
	state.initializing = false
	state.ready = true
	return true
end

function ClientGun._setupWelding(gun: Tool)
	-- Resolve ownership

	if not gun.Parent then
		return
	end

	local owner
	if gun.Parent:IsA("Backpack") then
		owner = gun.Parent.Parent
	else
		owner = Players:GetPlayerFromCharacter(gun.Parent)
	end
	if not owner then
		return
	end
	local character, humanoid =
		PlayerUtils.waitForObjects(owner, "Character", "Humanoid")
	local torso = character:WaitForChild("UpperTorso", 7)
	if not torso then
		LOG:Debug("Upper torso not found")
		return
	end
	-- Attempt to find open slot. It might take a little time for
	-- an overwritten tool to be destroyed so we have to wrap this in
	-- a timed loop
	local weldFolder = InstModify.findOrCreateChild(character, "GunWelds", "Folder")
	local slot = nil
	for elapsed in MiscUtils.elapsed() do
		task.wait()
		-- Try to resolve slot
		for _, slotOption in BACKPACK_SETTINGS.WeldSlots do
			local existing = weldFolder:FindFirstChild(slotOption)
			if existing then
				-- Make sure tool still exists
				local toolName = existing:GetAttribute("ToolName")
				local isInBackpack = owner.Backpack:FindFirstChild(toolName)
				local isInCharacter = character:FindFirstChild(toolName)
				if not isInBackpack and not isInCharacter then
					existing:Destroy()
				else
					continue
				end
			end

			slot = slotOption
			break
		end

		-- Evaluate loop
		if slot then
			break
		end
		if elapsed > 5 then
			break
		end
	end

	if not slot then
		return
	end

	-- Create model and weld
	local weldModel = gun:WaitForChild("Model", 15)
	if not weldModel then
		LOG:Warning("Failed to load gun model in time")
		return
	end
	weldModel = weldModel:Clone()
	weldModel.Name = slot
	weldModel:SetAttribute("ToolName", gun.Name)
	for _, part: Part in pairs(weldModel:GetChildren()) do
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		for _, weld: WeldConstraint in pairs(part:GetChildren()) do
			if weld:IsA("WeldConstraint") then
				if weld.Part0 and weld.Part0.Name == "Handle" then
					weld:Destroy()
				end
				if weld.Part1 and weld.Part1.Name == "Handle" then
					weld:Destroy()
				end
			end
		end
	end
	weldModel.PrimaryPart = nil
	local weldModelAttachment =
		InstModify.create("Attachment", weldModel:FindFirstChildWhichIsA("BasePart"))
	local center = weldModel:GetPivot()
	weldModelAttachment.WorldCFrame = center
	local weld: WeldConstraint = Instance.new("RigidConstraint")
	weld.Attachment0 = character:WaitForChild("UpperTorso").BodyBackAttachment
	weld.Attachment1 = weldModelAttachment
	weld.Parent = weldModel
	if slot == "Primary1" then
		weldModelAttachment.WorldCFrame *= CFrame.new(0, 0.9, 0)
		weld.Attachment1.CFrame *= CFrame.Angles(0, 0, math.rad(90))
	elseif slot == "Primary2" then
		weldModelAttachment.WorldCFrame *= CFrame.new(0, -0.5, 0)
		weld.Attachment1.CFrame *= CFrame.Angles(0, 0, math.rad(90))
	end
	weldModel.Parent = weldFolder

	local function setTransparency(transparency: number)
		for _, d in weldModel:GetDescendants() do
			if not d:IsA("BasePart") and not d:IsA("Texture") then
				continue
			end
			d.Transparency = transparency
		end
	end

	local function evaluateWeld()
		if not gun.Parent then
			weldModel:Destroy()
		elseif gun.Parent == character then
			setTransparency(1)
		else
			setTransparency(torso.Transparency)
		end
	end

	evaluateWeld()

	humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
		if humanoid.Sit then
			setTransparency(1)
		else
			setTransparency(torso.Transparency)
		end
	end)

	gun:GetPropertyChangedSignal("Parent"):Connect(evaluateWeld)

	torso:GetPropertyChangedSignal("Transparency"):Connect(function()
		evaluateWeld()
	end)
end

return ClientGun
