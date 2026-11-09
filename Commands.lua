local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage.Modules

local admin = require(Modules.Mega.Command.Admin)

-- The owner is passed in because its ModuleScript is still initializing.
return function(GunUtils)
	local gbuild = admin:AddCommand("gbuild", 5, "Give a gun to the specified player(s)")
	gbuild:AddPositional("name", "Name of gun to give")

	gbuild.Action = function(_self, args)
		local targets = args[".targets"] or { args[".caller"] }
		local name = args["name"]
		for _, target in targets do
			GunUtils.giveGun(target, name)
		end
	end

	----------------------------------------

	local grand =
		admin:AddCommand("grand", 10, "Give a random gun to the specified player(s)")

	grand.Action = function(_self, args)
		local targets = args[".targets"] or { args[".caller"] }
		for _, target in targets do
			GunUtils.giveRandomGun(target)
		end
	end
end
