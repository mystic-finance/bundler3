// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/StdJson.sol';
import 'forge-std/console.sol';
import {Bundler3} from 'src/Bundler3.sol';


contract DeployBundler is  Script {
  using stdJson for string;

  function run() external {  
    console.log('Morpho Bundler');
    console.log('sender', msg.sender);

   
    vm.startBroadcast();

    Bundler3 bundler = new Bundler3();

    console.log('bundler', address(bundler));

    vm.stopBroadcast();

  }
}


// Bundle3 - 0x53838C7bdaa0d5693F342f88c8D1567e58BdC7fa