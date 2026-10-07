// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BurnSwapPFP} from "../src/BurnSwapPFP.sol";

/// @notice Deploys BurnSwapPFP. Mint and swap both start closed; open them with `cast send` (see README).
///
/// Env vars:
///   NFT_NAME, NFT_SYMBOL   required
///   BASE_URI               optional, e.g. ipfs://<cid>/  (tokenURI = BASE_URI + id + ".json")
///   MAX_PER_WALLET         optional, default 10
///   OWNER                  optional, default is the deploying account
contract Deploy is Script {
    function run() external returns (BurnSwapPFP nft) {
        string memory name = vm.envString("NFT_NAME");
        string memory symbol = vm.envString("NFT_SYMBOL");
        string memory baseURI = vm.envOr("BASE_URI", string(""));
        uint256 maxPerWallet = vm.envOr("MAX_PER_WALLET", uint256(10));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);

        nft = new BurnSwapPFP(name, symbol, owner, baseURI, maxPerWallet);
        vm.stopBroadcast();

        console.log("BurnSwapPFP deployed at", address(nft));
        console.log("Owner", owner);
        console.log("Max per wallet", maxPerWallet);
    }
}
