// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {
    function run() external {
        vm.startBroadcast();

        new KipuBankV3(
            0x7E0987E5b3a30e3f2828572Bb659A548460a3003,
            0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
            0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9,
            1000000000000
        );

        vm.stopBroadcast();
    }
}
