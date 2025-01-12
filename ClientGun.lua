local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
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

local LOG = Logging:new("Guns.ClientGun")
local SETTINGS = require(ReplicatedStorage.Settings.Guns)
local BACKPACK_SETTINGS = require(ReplicatedStorage.Settings.Backpack)

local LocalPlayer = Players.LocalPlayer

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
	self.handle = self.object.Handle
	self.lastFire = 0
	self.lastAimChange = 0
	self.canAim = true
	self.isAiming = false

	-- Base table
	self.__clientcaster.new(self, tool)
	self.currentAmmo = self.settings.Gun.Capacity
	self.remoteFunction = self.object:WaitForChild("RemoteFunction")

	-- Ui
	self.ui = self.player.PlayerGui.Gun
	self.hotbar = self.player.PlayerGui.HUD.Hotbar
	--self.hotbar[self:_GetSlot()].Count.TextColor3 = Color3.new(1, 1, 1)

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

	-- Time anims and sound
	local reloadTime = self.settings.Gun.ReloadTime
	self.handle.Reload.PlaybackSpeed = self.handle.Reload.TimeLength / reloadTime

	repeat
		task.wait()
	until self.animManager["Reload"].Length > 0
	repeat
		task.wait()
	until self.animManager["Equip"].Length > 0
	self.reloadAnimSpeed = self.animManager["Reload"].Length / reloadTime
end

function ClientGun:_SetupEffects()
	-- Firing
	local gun = self.object
	local handle = gun.Handle
	self.fireSoundCache = ICache:new(handle.Fire, { parent = handle })
	self.effectsManager = EffectsManager:new(gun:GetDescendants())
end

-- =============== Firing ==============

function ClientGun:Fire(pos: Vector3)
	local fired = self:_FireFunctionality(pos)
	if not fired then
		return
	end
	self:_FireEffects()
	self:_FireAnimations()
	self:_FireInterface()
end

function ClientGun:_FireFunctionality(pos): boolean
	if self.currentAmmo < 1 then
		self:Reload()
		return false
	end
	if not self:_CanFire() then
		return false
	end

	-- Adjust spread
	local spreadAdj = 1
	if self.isFullyAimed then
		spreadAdj *= self.settings.Gun.AimSpreadAdj or SETTINGS.DefaultAimSpreadAdj
	end
	if AMS.isCrouching then
		spreadAdj *= self.settings.Gun.CrouchSpreadAdj or SETTINGS.DefaultCrouchSpreadAdj
	end

	-- Firing
	local thisFire = tick()
	self.lastFire = thisFire
	self.currentAmmo -= 1
	for i = 1, self.settings.Gun.BulletsPerShot or 1 do
		self:Cast(pos, spreadAdj)
	end

	-- Recoil
	if not self.isMobile then
		Strafer.TargetVertAngleOffset += self.settings.Gun.VerticalRecoil
		task.delay(
			math.clamp((1 / self.settings.Gun.FireRate) * 1.5, 0, 0.5),
			function()
				if self.lastFire == thisFire then
					Strafer.TargetVertAngleOffset = 0
				end
			end
		)
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
		task.delay((1 / self.settings.Gun.FireRate) * 0.3, function()
			self.animManager["Bolt"]:Play()
			self.effectsManager:Run("Bolt")
		end)
	end
	self.animManager["Shoot"]:Play()
end

function ClientGun:_FireInterface()
	local slot = self:_GetSlot()
	self.hotbar[slot].Count.Text = math.floor(self.currentAmmo)
	if self.currentAmmo / self.settings.Gun.Capacity <= 0.1 then
		self.hotbar[slot].Count.TextColor3 = Color3.new(1, 0.376471, 0.376471)
	else
		self.hotbar[slot].Count.TextColor3 = Color3.new(1, 1, 1)
	end
end

function ClientGun:_FireEffects()
	local sound = self.fireSoundCache:Get()
	sound:Play()
	sound.Ended:Connect(function()
		self.fireSoundCache:Return(sound)
	end)
	self.effectsManager:RunAll("Fire")
end

function ClientGun:_CanFire()
	local factors = {
		tick() - self.lastFire >= 1 / self.settings.Gun.FireRate,
		self.object.Parent == self.character,
		self.currentAmmo > 0,
		not self.isReloading,
		self.humanoid.Health > 0,
	}
	return not table.find(factors, false)
end

-- =============== Reloading ==============

function ClientGun:Reload()
	local canReload = not self.isReloading
		and self.currentAmmo ~= self.settings.Gun.Capacity
	if not canReload then
		return false
	end
	self:_ReloadEffects()
	self:_ReloadFunctionality()
	self.hotbar[self:_GetSlot()].Count.Text = self.currentAmmo
end

function ClientGun:_ReloadFunctionality()
	if not self.settings.Gun.AllowAimingOnReload then
		self:ToggleAim(false)
		self.canAim = false
	end

	self.isReloading = true
	local newAmmo = self.remoteFunction:InvokeServer("Reload")
	self.canAim = true
	if newAmmo == self.currentAmmo then
		self.isReloading = false
		return false
	end
	self.currentAmmo = newAmmo or self.currentAmmo

	self.isReloading = false
	return true
end

function ClientGun:_ReloadEffects()
	-- Animations
	self.animManager["Reload"]:Play(1, 1, self.reloadAnimSpeed)

	-- Ui
	local slot = self:_GetSlot()
	if self.currentAmmo / self.settings.Gun.Capacity <= 0.1 then
		self.hotbar[slot].Count.TextColor3 = Color3.new(1, 0.376471, 0.376471)
	else
		self.hotbar[slot].Count.TextColor3 = Color3.new(1, 1, 1)
	end
end

-- =============== Aiming ==============

function ClientGun:ToggleAim(enabled: boolean)
	if not self.canAim or self.isAiming == enabled then
		return
	end
	AMS:EndSprint()
	local targetFOV = nil
	local tweenInfo = TweenInfo.new(self.settings.Gun.AimSpeed, Enum.EasingStyle.Linear)

	self.isAiming = enabled

	local thisAim = tick()
	self.lastAimChange = thisAim

	if enabled then
		self:_RequestTorsoLock(true)
		local zoomSettings = Strafer.CameraSettings.ZoomedShoulder
		local mobileAimAdj = 1
		if self.isMobile and not self.settings.Gun.Scope then
			mobileAimAdj = SETTINGS.MobileAimMult
		end
		targetFOV = SETTINGS.DefaultFOV
			* (1 / self.settings.Gun.AimFOVMult)
			* mobileAimAdj
		zoomSettings.FieldOfView = targetFOV
		zoomSettings.LerpSpeed = 1

		Strafer:SetActiveCameraSettings("ZoomedShoulder")
		self.effectsManager:Run("ZoomIn")
		local scopeSettings = self.settings.Gun.Scope
		if scopeSettings then
			self.ui.Dot.Visible = false
			Strafer:SetShoulderDirection(1)
			local scopeTween = TweenService:Create(
				self.ui.Scope,
				TweenInfo.new(self.settings.Gun.AimSpeed * 2),
				{ GroupTransparency = 0 }
			)
			scopeTween:Play()
			local gunLength = (
				self.settings.Caster.FirePoint.WorldCFrame.Position
				- self.object.Handle.position
			).Magnitude * 1.5
			local crouchAdj = AMS.isCrouching and 0 or 1
			-- Setup camera
			zoomSettings.Offset = CFrame.new(0.7, 1.2 * crouchAdj, -gunLength - 1)
		else
			zoomSettings.Offset = Strafer.CameraSettings.DefaultShoulder.Offset
		end
		--self._weldVis(self.weldFolder, 1)
		self.humanoid.WalkSpeed *= self.settings.Gun.AimWalkSpeedAdj
	else
		self.isFullyAimed = false
		self:_RequestTorsoLock(false)
		Strafer:SetActiveCameraSettings("DefaultShoulder")
		targetFOV = SETTINGS.DefaultFOV
		self.effectsManager:Run("ZoomOut")
		-- Return camera back to normal
		if self.settings.Gun.Scope then
			local scopeTween = TweenService:Create(
				self.ui.Scope,
				TweenInfo.new(self.settings.Gun.AimSpeed),
				{ GroupTransparency = 1 }
			)
			scopeTween:Play()
			self.ui.Dot.Visible = true
		end
		--self._weldVis(self.weldFolder, 0)
		self.humanoid.WalkSpeed /= self.settings.Gun.AimWalkSpeedAdj
	end

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

-- =============== Equip/Unequip ==============

function ClientGun:Equip()
	if self.humanoid.sit then
		return
	end

	self.object:SetAttribute("IsEquipped", true)

	-- Strafer
	Strafer:SetActiveCameraSettings("DefaultShoulder")
	Strafer.Target = self.hrp
	Strafer:SetEnabled(true)

	self:_RequestTorsoLock(false)

	-- Ui
	self.ui.Dot.Visible = true
	self.hotbar[self:_GetSlot()].Count.Text = math.floor(self.currentAmmo)
	local scopeInfo = self.settings.Gun.Scope
	if scopeInfo then
		local scope = self.ui.Scope
		scope.Reticle.Image = scopeInfo.ReticleImage
		scope.Reticle.ImageTransparency = scopeInfo.BackgroundTransparency
		scope.Left.Transparency = scopeInfo.BackgroundTransparency
		scope.Right.Transparency = scopeInfo.BackgroundTransparency
		scope.Left.BackgroundColor3 = scopeInfo.BackgroundColor
		scope.Right.BackgroundColor3 = scopeInfo.BackgroundColor
	end

	-- Equip
	self.isEquipped = self.object.Parent ~= self.player.Backpack
	if self.isEquipped then
		self.humanoid.WalkSpeed *= self.settings.Gun.WalkspeedAdj
		self:_Hold()
	end

	self.effectsManager:RunAll("Equip")
end

function ClientGun:Unequip()
	if not self.isEquipped then
		return
	end
	self:ToggleAim(false)
	Strafer:SetEnabled(false)
	self.ui.Dot.Visible = false
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

function ClientGun._setupRemotes(gun: Tool | Model)
	local remoteEvent: RemoteEvent = gun:WaitForChild("RemoteEvent")
	local handle = gun:WaitForChild("Handle")

	local effectsManager =
		EffectsManager:new(handle, handle.FirePoint, handle:FindFirstChild("Ejector"))
	effectsManager:UpdateGroup("Fire", { "Emitter" })

	-- Setup sound cache
	local fireTemplate = gun:WaitForChild("Handle").Fire
	fireTemplate:WaitForChild("EqualizerSoundEffect")
	local soundCache = ICache:new(fireTemplate, { parent = handle })

	-- Configure emitter
	local gunSettings = require(gun.Settings)
	local emitter: ParticleEmitter = handle.FirePoint.Emitter
	local maxSpread = gunSettings.Caster.MaxSpread
	emitter.SpreadAngle = Vector2.new(maxSpread)
	emitter:SetAttribute("EmitCount", gunSettings.BulletsPerShot or 1)

	-- NOTE: for now, this event is only used for firing
	remoteEvent.OnClientEvent:Connect(function(castDistance: number?)
		-- Emitter distance
		if castDistance then
			emitter.Lifetime = NumberRange.new(castDistance / emitter.Speed.Max)
		else
			emitter.Lifetime = NumberRange.new(2)
		end

		-- Configure and play sound
		local sound: Sound = soundCache:Get()
		local success, err = pcall(function()
			local equalizer = sound.EqualizerSoundEffect
			local hrp = PlayerUtils.waitForObjects(LocalPlayer, "HumanoidRootPart")
			local distance = (handle.FirePoint.WorldPosition - hrp.Position).Magnitude
			if distance > sound.RollOffMaxDistance then
				return
			end
			if distance > SETTINGS.MuffleStartDistance then
				equalizer.Enabled = true
				local delta = distance - SETTINGS.MuffleStartDistance
				local muffleAdj = math.clamp(delta / SETTINGS.MaxMuffleDistance, 0, 1)
					* -80
				equalizer.HighGain = muffleAdj
				equalizer.MidGain = muffleAdj
				equalizer.LowGain = -muffleAdj / 6
			else
				equalizer.Enabled = false
			end
		end)
		if not success then
			LOG:Warning("Failed to configure distance equalizer: %s", err)
		end
		sound:Play()
		sound.Ended:Connect(function()
			soundCache:Return(sound)
		end)

		-- Run other effects
		effectsManager:RunAll("Fire")
	end)
end

function ClientGun._setupWelding(gun: Tool)
	-- Resolve ownership
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
	--weldModel.PrimaryPart = weldModel.PrimaryPart or weldModel:FindFirstChildWhichIsA('MeshPart')
	weldModel.PrimaryPart = nil
	local weldModelAttachment =
		InstModify.create("Attachment", weldModel:FindFirstChildWhichIsA("BasePart"))
	local center = weldModel:GetPivot()
	--weldModelAttachment.WorldCFrame = center * CFrame.new(0.5, 0, -0.2)
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
		for _, p in weldModel:GetChildren() do
			if not p:IsA("BasePart") then
				return
			end
			p.Transparency = transparency
		end
	end

	local function evaluateWeld()
		if not gun.Parent then
			weldModel:Destroy()
		elseif gun.Parent == character then
			setTransparency(1)
		else
			setTransparency(0)
		end
	end

	evaluateWeld()

	humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
		if humanoid.Sit then
			setTransparency(1)
		else
			setTransparency(0)
		end
	end)

	gun:GetPropertyChangedSignal("Parent"):Connect(evaluateWeld)
end

return ClientGun
