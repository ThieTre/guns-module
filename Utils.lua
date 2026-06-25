local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local Damage = require(Modules.Damage.Damage)
local PlayerData = require(Modules.PlayerData)

local scripts = script.Parent.Cloned

local SETTINGS = require(ReplicatedStorage.Settings.Guns)
local LOG = Logging:new("Guns.Utils")

-----------------------------------------------------------
----------------------- Gun Utils -------------------------
-----------------------------------------------------------

local Utils = {}

local function usesBurstFireRate(settings: {})
	local fireMode = settings.Gun.FireMode
	return fireMode == "Burst" or fireMode == "AutoBurst"
end

local function getBurstSize(settings: {})
	return settings.Gun.BurstSize or 1
end

local function getBurstDelay(settings: {})
	return settings.Gun.BurstDelay or settings.BurstDelay or 0
end

function Utils.giveGun(player: Player, name: string): Tool
	-- Give tool
	local assets = ServerStorage.Assets.Guns.Tools
	local tool = assets[name]:Clone()
	tool.Parent = player.Backpack

	for _, scriptName in { "Server", "Client" } do
		local scriptClone = scripts[scriptName]:Clone()
		scriptClone.Parent = tool
		scriptClone.Enabled = true
	end

	return tool
end

function Utils.giveRandomGun(player: Player): Tool
	local assets = ServerStorage.Assets.Guns.Tools
	local gunOptions = assets:GetChildren()
	local toolName = gunOptions[math.random(#gunOptions)].Name
	return Utils.giveGun(player, toolName)
end

function Utils.getDamage(settings: {})
	local base = settings.Damage.Damage
	local mult = settings.Damage.TypeMultipliers.Vehicle or 1

	local targetType = SETTINGS.VehicleDPSTypes
	local typeMults = settings.Damage.VehicleTypeMultipliers
	if targetType and typeMults then
		mult *= typeMults[targetType] or 1
	end

	local distanceInfo = settings.Damage.Distance
	if distanceInfo then
		local damageOptions = { Distance = table.clone(distanceInfo) }
		damageOptions.Distance.Distance = settings.Caster.MaxDistance / 2 -- simulate mid range
		mult *= Damage._getDecayMultiplier(damageOptions)
	end

	local pellets = settings.Gun.BulletsPerShot or 1
	return math.round(base * mult * pellets)
end

function Utils.getCycleTime(settings: {})
	local cap = settings.Gun.Capacity
	local reload = settings.Gun.ReloadTime
	local fireCooldown = 1 / settings.Gun.FireRate

	local timeToEmpty = 0
	if usesBurstFireRate(settings) then
		local remainingShots = cap
		local burstSize = getBurstSize(settings)
		local burstDelay = getBurstDelay(settings)

		while remainingShots > 0 do
			local shotsThisBurst = math.min(remainingShots, burstSize)
			timeToEmpty += math.max(0, shotsThisBurst - 1) * burstDelay
			remainingShots -= shotsThisBurst

			if remainingShots > 0 then
				timeToEmpty += fireCooldown
			end
		end
	else
		timeToEmpty = (cap - 1) * fireCooldown
	end

	return timeToEmpty + reload
end

function Utils.getDPS(settings: {})
	local totalDamage = Utils.getDamage(settings) * settings.Gun.Capacity
	local cycle = Utils.getCycleTime(settings)

	return math.round(totalDamage / cycle)
end

function Utils.getMechanicalRPM(settings: {})
	if usesBurstFireRate(settings) then
		local burstSize = getBurstSize(settings)
		local cycleDuration = (math.max(0, burstSize - 1) * getBurstDelay(settings))
			+ (1 / settings.Gun.FireRate)
		return math.round((burstSize / cycleDuration) * 60)
	end

	return math.round(settings.Gun.FireRate * 60)
end

function Utils.getEffectiveRPM(settings: {})
	local cycle = Utils.getCycleTime(settings)
	return math.round((settings.Gun.Capacity / cycle) * 60)
end

return Utils
