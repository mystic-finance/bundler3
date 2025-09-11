// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {MysticLeverageBundler} from "../../src/calls/MysticLeverageBundler.sol";
import {IMysticAdapter} from "../../src/interfaces/IMysticAdapter.sol";
import {IMaverickV2Pool} from "../../src/interfaces/IMaverickV2Pool.sol";
import {IMaverickV2Factory} from "../../src/interfaces/IMaverickV2Factory.sol";
import {IMaverickV2Quoter} from "../../src/interfaces/IMaverickV2Quoter.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBundler3, Call} from "../../src/interfaces/IBundler3.sol";
import {MysticAdapter} from "../../src/adapters/MysticAdapter.sol";
import {Bundler3, Call} from "../../src/Bundler3.sol";
import "../../lib/forge-std/src/Test.sol";
import "../helpers/mocks/ERC20Mock.sol";
import {ICreditDelegationToken} from "../../src/interfaces/ICreditDelegationToken.sol";
import {MaverickSwapAdapter} from "../../src/adapters/MaverickAdapter.sol";
import {IMysticV3 as IPool, ReserveDataMap as ReserveData} from "../../src/interfaces/IMysticV3.sol";

contract POC_Test is Test {
    function setUp() public  {
    }

    function test_POC() external {}
}