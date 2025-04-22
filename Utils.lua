local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)

local gunTools = ReplicatedStorage.Assets.Guns.Tools
local scripts = script.Parent.Cloned

local LOG = Logging:new("Guns.Utils")

-----------------------------------------------------------
----------------------- Gun Utils -------------------------
-----------------------------------------------------------

local Utils = {}

function Utils.giveGun(player: Player, name: string): Tool
	-- Give tool
	local tool = gunTools[name]:Clone()
	tool.Parent = player.Backpack
	for _, scriptName in { "Server", "Client" } do
		local scriptClone = scripts[scriptName]:Clone()
		scriptClone.Parent = tool
		scriptClone.Enabled = true
	end

	return tool
end

function Utils.giveRandomGun(player: Player): Tool
	local gunOptions = gunTools:GetChildren()
	local toolName = gunOptions[math.random(#gunOptions)].Name
	return Utils.giveGun(player, toolName)
end

function Utils.getDamage(settings: {})
	local base = settings.Damage.Damage
	local mult = settings.Damage.TypeMultipliers.Vehicle or 1
	local pellets = settings.BulletsPerShot or 1
	return math.round(base * mult * pellets)
end

function Utils.getCycleTime(settings: {})
	local rps = settings.Gun.FireRate
	local cap = settings.Gun.Capacity
	local reload = settings.Gun.ReloadTime
	local timeToEmpty = (cap - 1) / rps
	return math.round(timeToEmpty + reload)
end

function Utils.getDPS(settings: {})
	local totalDamage = Utils.getDamage(settings) * settings.Gun.Capacity
	local cycle = Utils.getCycleTime(settings)
	return math.round(totalDamage / cycle)
end

function Utils.getMechanicalRPM(settings: {})
	return math.round(settings.Gun.FireRate * 60)
end

function Utils.getEffectiveRPM(settings: {})
	local cycle = Utils.getCycleTime(settings)
	return math.round((settings.Gun.Capacity / cycle) * 60)
end

return Utils
