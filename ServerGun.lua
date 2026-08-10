local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local Instances = require(Modules.Mega.Instances)
local Decorators = require(Modules.Mega.Replication.Decorators)
local ServerCaster = require(Modules.Casting.ServerCaster)
local EffectsManager = require(Modules.Mega.Utils.EffectsManager)
local Notification = require(Modules.Mega.Interface.Notification)

local LOG = Logging:new("Guns.ServerGun")
local SETTINGS = require(ReplicatedStorage.Settings.Guns)
local FLOAT_TOLERANCE = 1e-6
local CASTING_SETTINGS = require(ReplicatedStorage.Settings.Casting)
local GUIDED_SETTINGS = CASTING_SETTINGS.GuidedLock or {}
-----------------------------------------------------------
---------------------- Server Gun -------------------------
-----------------------------------------------------------

local ServerGun = setmetatable(
	{ __servercaster = ServerCaster },
	{ __index = ServerCaster }
)
ServerGun.__index = ServerGun
export type ServerGun = typeof(ServerGun)

function ServerGun:new(object: Tool | Model)
	self = self ~= ServerGun and self or setmetatable({}, ServerGun)
	self.remoteFunction = Instances.Modify.findOrCreateChild(object, "RemoteFunction")
	self.remoteEvent = Instances.Modify.findOrCreateChild(object, "RemoteEvent")
	self.__servercaster.new(self, object)
	self.effectsManager = EffectsManager:new(
		self.object.Handle,
		self.object.Handle.FirePoint,
		self.object.Handle:FindFirstChild("Ejector")
	)
	self.hasBeenFired = false
	self.castType = self.settings.Caster.Type
	self.nextBarrelCount = 1
	self.reloadRequested = false
	self.reloadToken = 0
	self.pendingBurstShotsRemaining = 0
	self:SetCurrentAmmo(self.settings.Gun.Capacity)

	return self
end

function ServerGun:_Setup()
	self.bulletsPerShot = self.settings.Gun.BulletsPerShot or 1

	self.__servercaster._Setup(self)

	local emitterAttach = self.firePoint:FindFirstChild("EmitterAttachment")
	if emitterAttach then
		local emitter = self.firePoint.EmitterAttachment.Emitter
		emitter:SetAttribute("EmitCount", self.bulletsPerShot)
	end

	self:_SetupROFBucket()

	self.remoteFunction.OnServerInvoke = function(...)
		return self:_OnServerInvoke(...)
	end

	if not self.object:HasTag("gun") then
		self:_SetupModel()
	end
end

function ServerGun:_SetupModel()
	for _, part: BasePart in self.object.Model:GetChildren() do
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end

	Instances.Modify.create(
		"EqualizerSoundEffect",
		self.object.Handle.Fire,
		{ LowGain = 0, MidGain = 0 }
	)

	local handle = self.object:WaitForChild("Handle", 3)
	if not handle.Reload.IsLoaded then
		handle.Reload.Loaded:Wait()
	end
	local reloadTime = self.settings.Gun.ReloadTime
	handle.Reload.PlaybackSpeed = handle.Reload.TimeLength / reloadTime

	self.object:AddTag("gun")
end

function ServerGun:_OnServerInvoke(player: Player, typ: string, ...)
	if typ == "Reload" and player == self.player then
		return self:Reload(...)
	end
end

function ServerGun:_WarnGuidedTargetDriver(targetVehicle: Model?)
	if self.settings.Caster.TrailEffect ~= "HomingTarget" then
		return
	end
	if not targetVehicle or not targetVehicle.Parent then
		return
	end
	if not targetVehicle:HasTag("Vehicle") then
		return
	end
	local userId = targetVehicle:GetAttribute("DriverUserId")
	if not userId then
		return
	end

	local targetPart = targetVehicle:FindFirstChild("Body")
		and targetVehicle.Body:FindFirstChild("Main")
	if not targetPart or not targetPart:IsA("BasePart") then
		return
	end

	local maxDistance = self.settings.Caster.MaxDistance or math.huge
	local distance = (targetPart.Position - self.firePoint.WorldPosition).Magnitude
	if distance > maxDistance * 1.1 then
		return
	end

	local driverPlayer = Players:GetPlayerByUserId(userId)
	if not driverPlayer or driverPlayer == self.player then
		return
	end

	local cooldown = GUIDED_SETTINGS.DriverWarningCooldown or 7
	local now = os.time()
	local lastWarned = targetVehicle:GetAttribute("_LastGuideWarned") or -cooldown
	if now - lastWarned < cooldown then
		return
	end
	targetVehicle:SetAttribute("_LastGuideWarned", now)

	Notification.notify(
		driverPlayer,
		"Guided missile incoming! Aversion tactics reccomended.",
		{
			Title = "Warning",
			Sound = "Incoming",
			Color = Color3.fromHex("#ff6565"),
			QueuePos = 1,
		}
	)
end

function ServerGun:_ResolveOwnership()
	if self.object.Parent:IsA("Backpack") then
		self.player = self.object:FindFirstAncestorWhichIsA("Player")
	else
		self.player = game.Players:GetPlayerFromCharacter(self.object.Parent)
	end
	self.rayParameters.FilterDescendantsInstances =
		{ self.object, self.player.Character }

	self.__servercaster._ResolveOwnership(self)
end

function ServerGun:_UsesBurstFireRate(): boolean
	local fireMode = self.settings.Gun.FireMode
	return fireMode == "Burst" or fireMode == "AutoBurst"
end

function ServerGun:_GetFireRateRampSettings(): {}?
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

function ServerGun:_GetBurstSize(): number
	return self.settings.Gun.BurstSize or 1
end

function ServerGun:_GetBurstDelay(): number
	return self.settings.Gun.BurstDelay or self.settings.BurstDelay or 0
end

function ServerGun:_GetHeldFireDuration(): number
	if not self.fireRateRampStart then
		return 0
	end

	return tick() - self.fireRateRampStart
end

function ServerGun:_GetCurrentFireRate(): number
	local rampSettings = self:_GetFireRateRampSettings()
	if not rampSettings or not self.fireRateRampStart then
		return self.settings.Gun.FireRate
	end

	local alpha = math.clamp(self:_GetHeldFireDuration() / rampSettings.Duration, 0, 1)
	return rampSettings.StartRate
		+ ((self.settings.Gun.FireRate - rampSettings.StartRate) * alpha)
end

function ServerGun:_GetFireCooldownDuration(): number
	return 1 / self:_GetCurrentFireRate()
end

function ServerGun:_LockFireCooldown(duration: number?)
	duration = duration or 0
	local previousNextFireTime = self.nextServerFireTime or 0
	local nextFireTime = math.max(previousNextFireTime, tick() + duration)
	self.nextServerFireTime = nextFireTime
end

function ServerGun:_RequestReload(ignoreCapacity: boolean?): boolean
	local isAlreadyFull = (
		not ignoreCapacity and self.settings.Gun.Capacity == self.currentAmmo
	)
	if self.reloadRequested or self.isReloading or isAlreadyFull then
		return false
	end

	self.reloadRequested = true
	task.spawn(function()
		self:Reload(ignoreCapacity)
		self.reloadRequested = false
	end)

	return true
end

function ServerGun:_ResetServerFireCadence()
	self.pendingBurstShotsRemaining = 0
	self.reloadRequested = false
	self:ResetFireRateRamp()
end

function ServerGun:ResetFireRateRamp()
	self.fireRateRampStart = nil
end

function ServerGun:_SetupROFBucket()
	local gunSettings = self.settings.Gun
	local refillWindow = SETTINGS.ROFBucket.RefillRate
	local leaniance = SETTINGS.ROFBucket.Leniance
	local trueFireRate = gunSettings.FireRate
	if self:_UsesBurstFireRate() then
		local burstSize = self:_GetBurstSize()
		local burstCycleDuration = self:_GetFireCooldownDuration()
			+ math.max(0, burstSize - 1) * self:_GetBurstDelay()

		trueFireRate = burstSize / burstCycleDuration
		leaniance *= 1.05
	end
	self.bucketSize = 0
	self.bucketRefillWindow = refillWindow
	self.bucketResetAt = tick() + refillWindow
	self.maxBucketSize = (trueFireRate * refillWindow * (leaniance + 1))
		* self.bulletsPerShot
end

function ServerGun:_RefreshROFBucket(now: number?)
	now = now or tick()
	local bucketResetAt = self.bucketResetAt
	local refillWindow = self.bucketRefillWindow
	if not bucketResetAt or not refillWindow then
		return
	end
	if now < bucketResetAt then
		return
	end

	self.bucketSize = 0
	self.bucketResetAt = now + refillWindow
end

function ServerGun:SetCurrentAmmo(value: number)
	if math.abs(value) <= FLOAT_TOLERANCE then
		self.currentAmmo = 0
	else
		self.currentAmmo = value
	end
end

function ServerGun:_NotifyCastRejected(player: Player, id: number?)
	if id == nil then
		return
	end

	self:GetScorer(player):MarkCastRejected(id)
	self.remoteEvent:FireClient(player, {
		Type = "CastRejected",
		Id = id,
	})
end

function ServerGun:_OnCastEvent(
	player: Player,
	startPos: Vector3,
	endPos: Vector3,
	id: number,
	metadata: {
		speed: number?,
		guidedTarget: Model?,
	}?
): boolean
	if self.currentAmmo <= 0 then
		LOG:Debug("Cast event rejected due to no remaining ammo")
		self:_NotifyCastRejected(player, id)
		return false
	end

	if not self.hasBeenFired then
		self.hasBeenFired = true
		if SETTINGS.RemoveForceFieldOnFire then
			if self.player.Character then
				Instances.Modify.destroyExistingChild(
					self.player.Character,
					"ForceField"
				)
			end
		end
	end

	local isValid = self:_CheckROF()
	if not isValid then
		self:_NotifyCastRejected(player, id)
		return false
	end

	if self.castType ~= "Self" then
		local rayResults, accepted = self.__servercaster._OnCastEvent(
			self,
			player,
			startPos,
			endPos,
			id,
			metadata
		)
		if accepted == false then
			self:_NotifyCastRejected(player, id)
			return false
		end
		self:_WarnGuidedTargetDriver(metadata and metadata.guidedTarget)

		for _, otherPlayer in game.Players:GetPlayers() do
			if otherPlayer == self.player then
				continue
			end
			self.remoteEvent:FireClient(
				otherPlayer,
				(rayResults and rayResults.Distance) or nil
			)
		end
	end

	self:SetCurrentAmmo(self.currentAmmo - 1 / self.bulletsPerShot)
	self.bucketSize += 1

	return true
end

function ServerGun:_OnHitEvent(player, ...)
	if self.castType == "Self" then
		local canCast = self:_OnCastEvent()
		if not canCast then
			return
		end
	end
	self.__servercaster._OnHitEvent(self, player, ...)
end

function ServerGun:_CheckROF(): boolean
	self:_RefreshROFBucket()
	if self.bucketSize > self.maxBucketSize then
		LOG:Warning("Cast event rejected due ROF violation")
		return false
	end
	return true
end

function ServerGun:_CanDirectFire(): boolean
	return (
		tick() >= (self.nextServerFireTime or 0)
		and self.currentAmmo > 0
		and not self.isReloading
	)
end

function ServerGun:_BroadcastObserverFire(castDistance: number?)
	for _, player in Players:GetPlayers() do
		self.remoteEvent:FireClient(player, castDistance)
	end
end

function ServerGun:DirectFireAt(
	dealer: any,
	pos: Vector3,
	options: {
		ignoreFireCheck: boolean?,
		guidedTarget: Model?,
		skipROFCheck: boolean?,
	}?
): boolean
	options = options or {}

	local cooldownRemaining = math.max((self.nextServerFireTime or 0) - tick(), 0)
	if not options.ignoreFireCheck and cooldownRemaining > 0 then
		return false
	end
	if self.isReloading then
		return false
	end
	if self.currentAmmo < 1 then
		self:_RequestReload()
		return false
	end
	if not options.skipROFCheck and not self:_CheckROF() then
		return false
	end
	if not self:PrepareProjectileLaunch(true) then
		return false
	end

	local fireStartedAt = tick()
	if not self.fireRateRampStart then
		self.fireRateRampStart = fireStartedAt
	end

	local previousNextFireTime = self.nextServerFireTime or 0
	local previousPendingBurstShotsRemaining = self.pendingBurstShotsRemaining
	local cooldownDuration = self:_GetFireCooldownDuration()
	local observerFireBroadcasted = false
	if self:_UsesBurstFireRate() and self:_GetBurstSize() > 1 then
		if self.pendingBurstShotsRemaining > 0 then
			self.pendingBurstShotsRemaining -= 1
		else
			self.pendingBurstShotsRemaining = self:_GetBurstSize() - 1
		end

		if self.pendingBurstShotsRemaining > 0 then
			cooldownDuration = self:_GetBurstDelay()
		end
	else
		self.pendingBurstShotsRemaining = 0
	end

	self:_LockFireCooldown(cooldownDuration)

	local success, fired = pcall(function()
		local anyAccepted = false
		local castDistance = nil
		for bulletIndex = 1, self.bulletsPerShot do
			local accepted, currentDistance =
				self.__servercaster.DirectCast(self, dealer, pos, {
					guidedTarget = options.guidedTarget,
					ignoreProjectileLimit = true,
					observerFireCallback = function(observerCastDistance: number?)
						if observerFireBroadcasted then
							return
						end
						observerFireBroadcasted = true
						self:_BroadcastObserverFire(observerCastDistance)
					end,
				})
			if accepted then
				anyAccepted = true
				castDistance = castDistance or currentDistance
			end
		end
		if not anyAccepted then
			self.nextServerFireTime = previousNextFireTime
			self.pendingBurstShotsRemaining = previousPendingBurstShotsRemaining
			return false, nil
		end

		self.hasBeenFired = true
		self:SetCurrentAmmo(self.currentAmmo - 1)
		self.bucketSize += self.bulletsPerShot

		self:_WarnGuidedTargetDriver(options.guidedTarget)
		if not observerFireBroadcasted then
			self:_BroadcastObserverFire(castDistance)
		end

		if self.currentAmmo < 1 then
			self:_RequestReload()
		end

		return true, castDistance
	end)

	if not success then
		error(fired)
	end
	if not fired then
		return false
	end

	return true
end

function ServerGun:_IsReloadStillValid(reloadToken: number): boolean
	if self.reloadToken ~= reloadToken or not self.object.Parent then
		return false
	end

	if self.object:IsA("Tool") then
		local player = self.player
		local character = player and player.Character
		return character ~= nil and self.object.Parent == character
	end

	return true
end

function ServerGun:Reload(ignoreCapacity: boolean)
	LOG:Debug("Reload requested for %s", self.object.Name)
	local isAlreadyFull = (
		not ignoreCapacity and self.settings.Gun.Capacity == self.currentAmmo
	)
	if self.isReloading or isAlreadyFull then
		LOG:Warning("Reload request rejected")
		return self.currentAmmo
	end

	self:ResetFireRateRamp()
	self.reloadRequested = false
	self.reloadToken += 1
	local reloadToken = self.reloadToken
	self.isReloading = true

	self.effectsManager:RunAll("Reload")

	self:_SetHiddenParts(false)

	local function cancelReload()
		self.isReloading = false
		if self.effectsManager["Reload"] then
			self.effectsManager["Reload"]:Stop()
		end
		self:_SetHiddenParts(true)
		return self.currentAmmo
	end

	local cancelled = false
	local cancelCon = self.object:GetPropertyChangedSignal("Parent"):Once(function()
		cancelled = true
	end)
	local start = tick()
	while (tick() - start) < self.settings.Gun.ReloadTime do
		task.wait()
		if cancelled or not self:_IsReloadStillValid(reloadToken) then
			cancelCon:Disconnect()
			return cancelReload()
		end
	end
	cancelCon:Disconnect()

	if not self:_IsReloadStillValid(reloadToken) then
		return cancelReload()
	end

	self:SetCurrentAmmo(self.settings.Gun.Capacity)
	self.isReloading = false

	self:_SetHiddenParts(true)

	return self.currentAmmo
end

function ServerGun:_SetHiddenParts(visible: boolean)
	local model = self.object:FindFirstChild("Model")
	if not model then
		return
	end
	for _, p in model:GetChildren() do
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

return ServerGun
