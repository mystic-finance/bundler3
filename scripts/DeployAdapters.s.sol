// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/StdJson.sol';
import 'forge-std/console.sol';
import {Bundler3} from 'src/Bundler3.sol';
import {AaveAdapter} from 'src/adapters/AaveAdapter.sol';
import {MaverickSwapAdapter} from 'src/adapters/MaverickAdapter.sol';
import {AaveLeverageBundler} from 'src/calls/AaveLeverageBundler.sol';

contract DeployAdaptersAndBundler is Script {
    using stdJson for string;

    // Deployment configuration - modify these values for your target network
    address public constant AAVE_POOL_ADDRESS = 0xCE192A6E105cD8dd97b8Dedc5B5b263B52bb6AE0; // Mainnet Aave V3 Pool
    address public constant WNATIVE = 0xEa237441c92CAe6FC17Caaf9a7acB3f953be4bd1; // Mainnet Aave Oracle
    address public constant MAVERICK_FACTORY = 0x056A588AfdC0cdaa4Cab50d8a4D2940C5D04172E; // Mainnet Maverick Factory
    address public constant MAVERICK_QUOTER = 0xf245948e9cf892C351361d298cc7c5b217C36D82; // Mainnet Maverick Quoter
    
    // If you want to use existing Bundler3, set this address
    address public constant EXISTING_BUNDLER = 0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa; // Set to 0 to deploy a new one

    function run() external {
        console.log('Deploying Aave Leverage Components');
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
        MaverickSwapAdapter maverickAdapter = new MaverickSwapAdapter(
            MAVERICK_FACTORY,
            MAVERICK_QUOTER
        );
        console.log('Deployed MaverickSwapAdapter:', address(maverickAdapter));

        // 3. Deploy Aave Adapter
        AaveAdapter aaveAdapter = new AaveAdapter(
            address(bundler),
            AAVE_POOL_ADDRESS,
            WNATIVE
        );
        console.log('Deployed AaveAdapter:', address(aaveAdapter));

        // 4. Deploy AaveLeverageBundler
        AaveLeverageBundler leverageBundler = new AaveLeverageBundler(
            address(bundler),
            address(aaveAdapter),
            address(maverickAdapter)
        );
        console.log('Deployed AaveLeverageBundler:', address(leverageBundler));

        vm.stopBroadcast();

        // Output summary
        console.log("\n=== Deployment Summary ===");
        console.log("Bundler3:", address(bundler));
        console.log("MaverickSwapAdapter:", address(maverickAdapter));
        console.log("AaveAdapter:", address(aaveAdapter));
        console.log("AaveLeverageBundler:", address(leverageBundler));
    }
}

// === Deployment Summary ===
//   Bundler3: 0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa
//   MaverickSwapAdapter: 0xE5624863E589118A3E68Cd0410Ed5aBF2b90287d
//   AaveAdapter: 0x09FEdB229614ae90c3bbfBDB9Eeb487dDa8af7B4
//   AaveLeverageBundler: 0xEA7df17352088F24B2A3E5e66108B4978EA20dCd

// maverick  old -  0x8Cc909CE0543b40E308F0ad69316De5894F655c8
// aave old - 0x81E0C8ed445599c086336D8E1A0e56Dc1948812a
// leverage old - 0x585e35c9E537f1f9f1d6c350B9B91833F8e2c71f