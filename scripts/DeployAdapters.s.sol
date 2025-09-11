// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/StdJson.sol';
import 'forge-std/console.sol';
import {Bundler3} from 'src/Bundler3.sol';
import {MysticAdapter} from 'src/adapters/MysticAdapter.sol';
import {MaverickSwapAdapter} from 'src/adapters/MaverickAdapter.sol';
import {MysticLeverageBundler} from 'src/calls/MysticLeverageBundler.sol';

contract DeployAdaptersAndBundler is Script {
    using stdJson for string;

    // Deployment configuration - modify these values for your target network
    address public constant AAVE_POOL_ADDRESS = 0xCE192A6E105cD8dd97b8Dedc5B5b263B52bb6AE0; // Mainnet Mystic V3 Pool
    address public constant WNATIVE = 0xEa237441c92CAe6FC17Caaf9a7acB3f953be4bd1; // Mainnet Mystic Oracle
    address public constant MAVERICK_FACTORY = 0x056A588AfdC0cdaa4Cab50d8a4D2940C5D04172E; // Mainnet Maverick Factory
    address public constant MAVERICK_QUOTER = 0xf245948e9cf892C351361d298cc7c5b217C36D82; // Mainnet Maverick Quoter
    
    // If you want to use existing Bundler3, set this address
    address public constant EXISTING_BUNDLER = 0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa; // Set to 0 to deploy a new one

    function run() external {
        console.log('Deploying Mystic Leverage Components');
        console.log('Deployer:', msg.sender);

        vm.startBroadcast();

        // 1. Deploy or use existing Bundler3
        Bundler3 bundler = Bundler3(0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa);
        if (EXISTING_BUNDLER == address(0)) {
            bundler = new Bundler3();
            console.log('Deployed Bundler3:', address(bundler));
        } else {
            bundler = Bundler3(EXISTING_BUNDLER);
            console.log('Using existing Bundler3:', address(bundler));
        }

        // 2. Deploy Maverick Adapter
        // MaverickSwapAdapter maverickAdapter = new MaverickSwapAdapter(
        //     MAVERICK_FACTORY,
        //     MAVERICK_QUOTER
        // );
        // console.log('Deployed MaverickSwapAdapter:', address(maverickAdapter));

        // // 3. Deploy Mystic Adapter
        // MysticAdapter aaveAdapter = new MysticAdapter(
        //     address(bundler),
        //     AAVE_POOL_ADDRESS,
        //     WNATIVE
        // );
        // console.log('Deployed MysticAdapter:', address(aaveAdapter));

        // 4. Deploy MysticLeverageBundler
        MysticLeverageBundler leverageBundler = new MysticLeverageBundler(
            address(bundler),
            address(0xE2314ECb6Ae07a987018a71e412897ED2F54E075),
            address(0x4bc5023204C67633c33A33cDBfFCb1FB14126c17)
        );
        console.log('Deployed MysticLeverageBundler:', address(leverageBundler));

        vm.stopBroadcast();

        // Output summary
        console.log("\n=== Deployment Summary ===");
        console.log("Bundler3:", address(bundler));
        // console.log("MaverickSwapAdapter:", address(maverickAdapter));
        // console.log("MysticAdapter:", address(aaveAdapter));
        console.log("MysticLeverageBundler:", address(leverageBundler));
    }
}


// // === Deployment Summary ===
//   Bundler3: 0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa
// mystic adapter 0xE2314ECb6Ae07a987018a71e412897ED2F54E075
//   MysticLeverageBundler: 0x518E95D663Ac901cc7D81e23a47516b0a93Cb675
  
// old
// mystic adapter 0xE2314ECb6Ae07a987018a71e412897ED2F54E075
// mystic leverage bundler 0x598Fc8cD4335D5916Fa81Ec0Efa25b462aA721F1

// == Logs ==
//   Deploying Mystic Leverage Components
//   Deployer: 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38
//   Using existing Bundler3: 0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa
//   Deployed MaverickSwapAdapter: 0x4bc5023204C67633c33A33cDBfFCb1FB14126c17
//   Deployed MysticAdapter: 0x968A22e4CEdfE0Dd5e1aE4C6541Fa73f28da2b9f
//   Deployed MysticLeverageBundler: 0x9928b8bcC7DeA72cFb49958a14A971389fd178e6  0x23a4FB4447091fDef4f21D12D28675327B947Ee0-old

// old
// === Deployment Summary ===
//   Bundler3: 0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa
//   MaverickSwapAdapter: 0xE5624863E589118A3E68Cd0410Ed5aBF2b90287d
//   MysticAdapter: 0x09FEdB229614ae90c3bbfBDB9Eeb487dDa8af7B4
//   MysticLeverageBundler: 0xEA7df17352088F24B2A3E5e66108B4978EA20dCd

// maverick  old -  0x8Cc909CE0543b40E308F0ad69316De5894F655c8
// aave old - 0x81E0C8ed445599c086336D8E1A0e56Dc1948812a
// leverage old - 0x585e35c9E537f1f9f1d6c350B9B91833F8e2c71f