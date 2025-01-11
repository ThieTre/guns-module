local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local Instances = require(Modules.Mega.Instances)
local ServerCaster = require(Modules.Casting.ServerCaster)
local EffectsManager = require(Modules.Mega.Utils.EffectsManager)

local LOG = Logging:new("Guns.ServerGun")
local SETTINGS = require(ReplicatedStorage.Settings.Guns)

-----------------------------------------------------------
---------------------- Server Gun -------------------------
-----------------------------------------------------------

local ServerGun = setmetatable({}, { __index = ServerCaster })
ServerGun.__index = ServerGun
export type ServerGun = typeof(setmetatable({}, ServerGun))

function ServerGun:new(object: Tool | Model)
	self = self ~= ServerGun and self or setmetatable({}, ServerGun)
	self.__servercaster = ServerCaster
	self.remoteFunction = Instances.Modify.findOrCreateChild(object, "RemoteFunction")
	self.remoteEvent = Instances.Modify.findOrCreateChild(object, "RemoteEvent")
	self.__servercaster.new(self, object)
	self.effectsManager = EffectsManager:new(
		self.object.Handle,
		self.object.Handle.FirePoint,
		self.object.Handle:FindFirstChild("Ejector")
	)
	self.currentAmmo = self.settings.Gun.Capacity

	return self
end

function ServerGun:_Setup()
	self.bulletsPerShot = self.settings.Gun.BulletsPerShot or 1

	self.__servercaster._Setup(self)

	self:_SetupROFBucket()

	self.remoteFunction.OnServerInvoke = function(...)
		return self:_OnServerInvoke(...)
	end

	if not self.object:HasTag("gun") then
		self:_SetupModel()
	end
end

function ServerGun:_SetupModel()
	self.object:AddTag("gun")

	-- Setup model
	for _, part: BasePart in self.object.Model:GetChildren() do
		part.CanCollide = false
	end

	Instances.Modify.create(
		"EqualizerSoundEffect",
		self.object.Handle.Fire,
		{ LowGain = 0, MidGain = 0 }
	)
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
		while true do
			task.wait(refillWindow)
			self.bucketSize = 0
		end
	end)
end

function ServerGun:_OnCastEvent(...)
	if self.currentAmmo <= 0 then
		-- Ammo mismatch between server and client should never happen
		-- unless a player is exploiting
		LOG:Debug("Cast event rejected due to no remaining ammo")
		return
	end

	self.currentAmmo -= 1 / self.bulletsPerShot -- decrease ammo count regardless of ROF violations
	if self.bucketSize > self.maxBucketSize then
		LOG:Warning("Cast event rejected due ROF violation")
		return
	end

	local rayResults: RaycastResult = self.__servercaster._OnCastEvent(self, ...)

	for _, player in game.Players:GetPlayers() do
		if player == self.player then
			continue
		end
		self.remoteEvent:FireClient(player, (rayResults and rayResults.Distance) or nil)
	end

	self.bucketSize += 1
end

function ServerGun:Reload()
	LOG:Debug("Reload requested for %s", self.object.Name)
	if self.isReloading or self.settings.Gun.Capacity == self.currentAmmo then
		LOG:Warning("Reload request rejected")
		return self.currentAmmo
	end

	self.isReloading = true

	self.effectsManager:RunAll("Reload")

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
			return self.currentAmmo
		end
	end

	-- Fill ammo
	self.currentAmmo = self.settings.Gun.Capacity
	self.isReloading = false

	return self.currentAmmo
end

return ServerGun
