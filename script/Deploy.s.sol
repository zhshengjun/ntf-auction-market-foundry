// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Auction} from "../src/Auction.sol";
import {JunNFT} from "../src/JunNFT.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script} from "forge-std/Script.sol";

contract Deploy is Script {
    function run() external returns (address auctionProxy, address nftProxy) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");

        vm.startBroadcast();

        Auction auctionImplementation = new Auction();
        auctionProxy = address(
            new ERC1967Proxy(address(auctionImplementation), abi.encodeCall(Auction.initialize, (initialOwner)))
        );

        JunNFT nftImplementation = new JunNFT();
        nftProxy = address(
            new ERC1967Proxy(address(nftImplementation), abi.encodeCall(JunNFT.initialize, (1000, initialOwner)))
        );

        vm.stopBroadcast();
    }
}
