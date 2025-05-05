# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# deps
update:; forge update


deploy-script-deploy-bundler :; forge script scripts/DeployBundler.s.sol:DeployBundler --chain 98866 --rpc-url https://phoenix-rpc.plumenetwork.xyz --broadcast --slow --verifier blockscout --verifier-url https://phoenix-explorer.plumenetwork.xyz/api? --legacy --gas-estimate-multiplier 150 --delay 5 --account deployer
plume-verify-bundler :; forge verify-contract 0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa src/Bundler3.sol:Bundler3 --chain 98866 --verifier blockscout --rpc-url https://phoenix-rpc.plumenetwork.xyz --verifier-url https://phoenix-explorer.plumenetwork.xyz/api? --watch
deploy-script-deploy-adapter :; forge script scripts/DeployAdapters.s.sol:DeployAdaptersAndBundler --chain 98866 --rpc-url https://phoenix-rpc.plumenetwork.xyz --broadcast --slow --verify --verifier blockscout --verifier-url https://phoenix-explorer.plumenetwork.xyz/api? --legacy --gas-estimate-multiplier 100 --delay 5 --account deployer


test-open-leverage-fork :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerRWATest --mt testAddCollateralWithDifferentInputAsset  -vvvvvvv
test-close-leverage-fork :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerElixirTest --mt testCreateCloseLeverageBundle1  -vvvvvvv
test-leverage-fork-gas-report :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerRWATest  -vvv --gas-report
test-leverage-fork-new-gas-report :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerElixirTest  -vvvvv --gas-report 


test-update-leverage-fork-increase-leverage :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerTest --mt testUpdateLeverageBundleIncreaseLeverageOnly  -vvvvvvv
test-update-leverage-fork-decrease-leverage :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerTest --mt testUpdateLeverageBundleDecreaseLeverageOnly  -vvvvvvv


test-update-leverage-fork-add-amount :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerTest --mt testUpdateLeverageBundleAddCollateralOnly  -vvvvvvv
test-update-leverage-fork-remove-amount :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerElixirTest --mt testUpdateLeverageBundleRemoveAllCollateral  -vvvvvvv


test-update-leverage-fork-add-collateral :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerTest --mt testUpdateLeverageBundleAddCollateralOnly  -vvvvvvv
test-update-leverage-fork-add-collateral-and-leverage :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerTest --mt testUpdateLeverageBundleIncreaseLeverageAndAddCollateral  -vvvvvvv
test-update-leverage-fork-add-collateral-and-remove-leverage :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerTest --mt testUpdateLeverageBundleIncreaseLeverageAndRemoveCollateral  -vvvvvvv
test-update-leverage-fork-remove-collateral-and-leverage :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerTest --mt testUpdateLeverageBundleDecreaseLeverageAndAddCollateral  -vvvvvvv
test-update-leverage-fork-remove-collateral-and-add-leverage :; forge test --fork-url https://phoenix-rpc.plumenetwork.xyz --mc MysticLeverageBundlerTest --mt testUpdateLeverageBundleDecreaseLeverageAndRemoveCollateral  -vvvvvvv
