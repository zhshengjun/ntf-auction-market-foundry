// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract JunNFT is ERC721EnumerableUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    error MaxSupplyReached();
    error NotTokenOwner();

    uint256 private _lastTokenId; // 默认 0
    uint256 private _maxSupply;

    function initialize(uint256 maxSupply_, address initialOwner) external initializer {
        __ERC721_init("JunNFT", "JNFT");
        __ERC721Enumerable_init();
        __Ownable_init(initialOwner);

        _maxSupply = maxSupply_;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * 铸造NFT
     */
    function mint(address to) external onlyOwner {
        if (totalSupply() >= _maxSupply) revert MaxSupplyReached();

        uint256 tokenId = ++_lastTokenId;
        _safeMint(to, tokenId);
    }

    /**
     * 销毁NFT
     */
    function burn(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        _burn(tokenId);
    }

    /**
     * @dev Reserved storage space to allow for layout changes in the future.
     */
    // 升级预留存储，不能按未使用变量删除。
    // forge-lint: disable-next-line(unused-state-variables)
    uint256[48] private __gap;
}
