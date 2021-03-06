genPBridgeGo:
	abigen -sol ./flatten/PBridge_Fla.sol -pkg pbridge_abi --out ./go_abi/pbridge_abi/PBridge.g.go
genERC20Go:
	abigen -sol ./flatten/ERC20Minter_Fla.sol -pkg merc20_abi --out ./go_abi/merc20_abi/ERC20Minter.g.go
genERC721Go:
	abigen -sol ./flatten/ERC721Minter_Fla.sol -pkg merc721_abi --out ./go_abi/merc721_abi/ERC721Minter.g.go
genGame721Go:
	abigen -sol ./flatten/Game721_Fla.sol -pkg game721_abi --out ./go_abi/game721_abi/Game721.g.go
genGame20Go:
	abigen -sol ./flatten/Game20_Fla.sol -pkg game20_abi --out ./go_abi/game20_abi/Game20.g.go