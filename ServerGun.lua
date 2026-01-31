local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local Instances = require(Modules.Mega.Instances)
local ServerCaster = require(Modules.Casting.ServerCaster)
local EffectsManager = require(Modules.Mega.Utils.EffectsManager)

local LOG = Logging:new("Guns.ServerGun")
local SETTINGS = require(ReplicatedStorage.Settings.Guns)
local FLOAT_TOLERANCE = 1e-6

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

function ServerGun:_SetupROFBucket()
	local gunSettings = self.settings.Gun
	local refillWindow = SETTINGS.ROFBucket.RefillRate
	local leaniance = SETTINGS.ROFBucket.Leniance
	local trueFireRate = gunSettings.FireRate
	if gunSettings.FireMode == "Burst" then
		-- Include burst delay in fire rate, be a little more leniate in bucket size
		trueFireRate = gunSettings.BurstSize
			/ ((gunSettings.BurstSize / gunSettings.FireRate) + gunSettings.BurstDelay)
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

function ServerGun:_OnCastEvent(...): boolean
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

	self:SetCurrentAmmo(self.currentAmmo - 1 / self.bulletsPerShot)

	local isValid = self:_CheckROF()
	if not isValid then
		return false
	end

	if self.castType ~= "Self" then
		local rayResults: RaycastResult = self.__servercaster._OnCastEvent(self, ...)

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

	self.bucketSize += 1

	if self.currentAmmo <= 0 then
		task.delay(0.1, function() -- TODO: fix this race
			self.remoteFunction:InvokeClient(self.player, "Reload")
		end)
	end

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

function ServerGun:Reload()
	LOG:Debug("Reload requested for %s", self.object.Name)
	if self.isReloading or self.settings.Gun.Capacity == self.currentAmmo then
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

return ServerGun
