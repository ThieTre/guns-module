local CollectionService = game:GetService("CollectionService")

local ClientGun =
	require(game.ReplicatedStorage:WaitForChild("Modules").Guns.ClientGun)

CollectionService:GetInstanceAddedSignal("gun"):Connect(ClientGun._setupClient)
