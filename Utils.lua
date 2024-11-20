local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local Table = require(Modules.Mega.DataStructures.Table)

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

return Utils
