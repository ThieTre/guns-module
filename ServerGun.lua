local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local Instances = require(Modules.Mega.Instances)
local Decorators = require(Modules.Mega.Replication.Decorators)
local ServerCaster = require(Modules.Casting.ServerCaster)
local EffectsManager = require(Modules.Mega.Utils.EffectsManager)
local Notification = require(Modules.Mega.Interface.Notification)
local Damage = require(Modules.Damage.Damage)

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
	-- Setup model
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

	-- Adjust reload sound duration
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

function ServerGun:_GetBurstSize(): number
	return self.settings.Gun.BurstSize or 1
end

function ServerGun:_GetBurstDelay(): number
	return self.settings.Gun.BurstDelay or self.settings.BurstDelay or 0
end

function ServerGun:_GetFireCooldownDuration(): number
	return 1 / self.settings.Gun.FireRate
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

		-- Include the full burst cycle in fire rate, be a little more leniate in bucket size
		trueFireRate = burstSize / burstCycleDuration
		leaniance *= 1.05
	end
	self.bucketSize = 0
	self.maxBucketSize = (trueFireRate * refillWindow * (leaniance + 1))
		* self.bulletsPerShot
	task.spawn(function()
		-- Refill bucket
		while self.object.Parent do
			task.wait(refillWindow)
			self.bucketSize = 0
		end
	end)
end

function ServerGun:SetCurrentAmmo(value: number)
	if math.abs(value) <= FLOAT_TOLERANCE then
		self.currentAmmo = 0
	else
		self.currentAmmo = value
	end
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
			return false
		end
		self:_WarnGuidedTargetDriver(metadata and metadata.guidedTarget)

		for _, player in game.Players:GetPlayers() do
			if player == self.player then
				continue
			end
			self.remoteEvent:FireClient(
				player,
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
		-- No cast event is ever fired so we have to validate
		-- cast here
		local canCast = self:_OnCastEvent()
		if not canCast then
			return
		end
	end
	self.__servercaster._OnHitEvent(self, player, ...)
end

function ServerGun:_CheckROF(): boolean
	if self.bucketSize > self.maxBucketSize then
		LOG:Warning("Cast event rejected due ROF violation")
		return false
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

	self.isReloading = true

	self.effectsManager:RunAll("Reload")

	self:_SetHiddenParts(false)

	-- Wait reload time
	local cancelled = false
	local cancelCon = self.object:GetPropertyChangedSignal("Parent"):Once(function()
		cancelled = true
	end)
	local start = tick()
	while (tick() - start) < self.settings.Gun.ReloadTime do
		task.wait()
		if cancelled then
			self.isReloading = false
			self.effectsManager["Reload"]:Stop()
			self:_SetHiddenParts(true)
			return self.currentAmmo
		end
	end
	cancelCon:Disconnect()

	-- Fill ammo
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
