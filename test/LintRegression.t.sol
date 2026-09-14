// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {JunNFT} from "../src/JunNFT.sol";
import {AuctionTestFeed} from "./Auction.t.sol";

// 本地回归测试：无需 RPC，金额/时间常量直接表达预期。
// forge-lint: disable-start(literal-instead-of-constant)
contract LintRegressionTest is Test, ERC721Holder {
    function test_NftCustomErrorsAndAuthorizedBurn() public {
        JunNFT nft = JunNFT(
            address(new ERC1967Proxy(address(new JunNFT()), abi.encodeCall(JunNFT.initialize, (1, address(this)))))
        );
        nft.mint(address(this));
        vm.expectRevert(JunNFT.MaxSupplyReached.selector);
        nft.mint(address(this));
        vm.prank(address(0xB1));
        vm.expectRevert(JunNFT.NotTokenOwner.selector);
        nft.burn(1);
        assertEq(nft.ownerOf(1), address(this));
        nft.burn(1);
        assertEq(nft.totalSupply(), 0);
    }

    function test_PriceConfigurationPreservesDisabledStateAndScales() public {
        Auction auction = Auction(
            address(new ERC1967Proxy(address(new Auction()), abi.encodeCall(Auction.initialize, (address(this)))))
        );
        vm.warp(100_000);
        AuctionTestFeed feed = new AuctionTestFeed();
        auction.configureToken(address(0), address(feed), 1 hours);
        (address source, uint8 tokenDecimals, uint8 feedDecimals, bool enabled, uint256 maxAge) =
            auction.priceConfigs(address(0));
        assertEq(source, address(feed));
        assertEq(tokenDecimals, 18);
        assertEq(feedDecimals, 8);
        assertTrue(enabled);
        assertEq(maxAge, 1 hours);
        assertEq(auction.quoteUsd(address(0), 1 ether), 1e18);
        auction.setTokenEnabled(address(0), false);
        feed.set(2e8, block.timestamp);
        auction.configureToken(address(0), address(feed), 2 hours);
        (source, tokenDecimals, feedDecimals, enabled, maxAge) = auction.priceConfigs(address(0));
        assertEq(source, address(feed));
        assertEq(tokenDecimals, 18);
        assertEq(feedDecimals, 8);
        assertFalse(enabled);
        assertEq(maxAge, 2 hours);
        assertEq(auction.quoteUsd(address(0), 1 ether), 2e18);
    }
}
