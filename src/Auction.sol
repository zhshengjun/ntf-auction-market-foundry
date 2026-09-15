// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice 托管 ERC721 的公开竞价拍卖；美元估值仅用于比较出价，不保证结算时的美元价值。
/// @dev 通过 ERC1967Proxy 使用。仅支持可信 ERC721 和白名单内的标准、非 rebase ERC20。
contract Auction is ERC721Holder, ReentrancyGuard, PausableUpgradeable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint8 private constant USD_DECIMALS = 18;
    uint256 private constant DECIMAL_BASE = 10;

    uint256 public constant MAX_DURATION = 30 days;

    enum Status {
        None,
        Active,
        Cancelled,
        Settled
    }

    struct AuctionItem {
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 reservePriceUsd;
        uint256 highestBidUsd;
        address highestBidder;
        uint256 endTime;
        Status status;
        bool nftClaimed;
    }

    struct Bid {
        address token; // address(0) 表示 ETH
        uint256 amount; // 同一币种累计托管的最小单位数量
    }

    struct PriceConfig {
        address feed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        bool enabled;
        uint256 maxAge;
    }

    struct ExpectedNft {
        address nftContract;
        address seller;
        uint256 tokenId;
    }

    uint256 public auctionCount;
    mapping(uint256 => AuctionItem) private _auctions;
    mapping(uint256 => mapping(address => Bid)) private _bids;
    mapping(address => PriceConfig) public priceConfigs;
    mapping(address => mapping(address => uint256)) public proceeds;
    // 每种币的总负债 = 未退竞价资金 + 卖家可提收入；结算不改变总负债。
    mapping(address => uint256) public totalLiabilities;
    ExpectedNft private _expectedNft;

    error InvalidAddress();
    error InvalidDuration();
    error InvalidAmount();
    error AuctionNotFound(uint256 auctionId);
    error AuctionNotActive(uint256 auctionId);
    error AuctionNotEnded(uint256 auctionId);
    error AuctionEnded(uint256 auctionId);
    error Unauthorized();
    error AuctionHasBids();
    error SellerCannotBid();
    error HighestBidLocked();
    error NothingToWithdraw();
    error BidTokenMismatch();
    error BidTooLow(uint256 valueUsd, uint256 minimumUsd);
    error UnsupportedToken(address token);
    error TokenDisabled(address token);
    error InvalidPriceConfig();
    error InvalidPrice();
    error StalePrice(uint256 updatedAt);
    error UnexpectedTokenAmount();
    error ETHTransferFailed();
    error InvalidNFT();
    error UnexpectedNFT();
    error NFTAlreadyClaimed();
    error OwnershipRequired();

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 reservePriceUsd,
        uint256 endTime
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        address indexed token,
        uint256 addedAmount,
        uint256 totalAmount,
        uint256 valueUsd
    );
    event AuctionCancelled(uint256 indexed auctionId);
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed winner,
        address token,
        uint256 amount,
        uint256 valueUsd
    );
    event NFTClaimed(uint256 indexed auctionId, address indexed claimant, address indexed recipient);
    event BidWithdrawn(
        uint256 indexed auctionId, address indexed bidder, address indexed token, address recipient, uint256 amount
    );
    event ProceedsWithdrawn(address indexed seller, address indexed token, address indexed recipient, uint256 amount);
    event PriceConfigured(
        address indexed token, address indexed feed, uint8 tokenDecimals, uint8 feedDecimals, uint256 maxAge
    );
    event TokenEnabled(address indexed token, bool enabled);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0) || initialOwner == address(this)) {
            revert InvalidAddress();
        }
        __Pausable_init();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @dev 禁止放弃管理员，避免合约暂停后永远无法恢复。
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice 添加或更新 token/USD 价格配置；更新保留启用状态及代币精度。
    /// @dev 新配置用于后续报价和出价，不重算已有出价的美元估值。
    function configureToken(address token, address feed, uint256 maxAge) external onlyOwner {
        PriceConfig memory previous = priceConfigs[token];
        bool configured = previous.feed != address(0);
        if (feed.code.length == 0 || maxAge == 0 || token == address(this)) {
            revert InvalidPriceConfig();
        }
        if (token != address(0) && token.code.length == 0) {
            revert UnsupportedToken(token);
        }
        uint8 tokenDecimals = token == address(0) ? USD_DECIMALS : IERC20Metadata(token).decimals();
        uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
        if (tokenDecimals > USD_DECIMALS || feedDecimals > USD_DECIMALS) {
            revert InvalidPriceConfig();
        }
        if (configured && tokenDecimals != previous.tokenDecimals) {
            revert InvalidPriceConfig();
        }
        PriceConfig memory config = PriceConfig({
            feed: feed,
            tokenDecimals: tokenDecimals,
            feedDecimals: feedDecimals,
            enabled: !configured || previous.enabled,
            maxAge: maxAge
        });
        _priceUsd18(config);
        priceConfigs[token] = config;
        // onlyOwner 配置入口只查询 view 接口，外部读取使用 STATICCALL。
        // forge-lint: disable-start(reentrancy-events)
        emit PriceConfigured(token, feed, tokenDecimals, feedDecimals, maxAge);
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @notice 停用仅禁止新出价，不妨碍已有资金结算、退款和提现。
    function setTokenEnabled(address token, bool enabled) external onlyOwner {
        if (priceConfigs[token].feed == address(0)) {
            revert UnsupportedToken(token);
        }
        priceConfigs[token].enabled = enabled;
        // 该入口只修改内部配置，不执行外部调用。
        // forge-lint: disable-start(reentrancy-events)
        emit TokenEnabled(token, enabled);
        // forge-lint: disable-end(reentrancy-events)
    }

    function getAuction(uint256 auctionId) external view returns (AuctionItem memory) {
        return _getAuction(auctionId);
    }

    function getBid(uint256 auctionId, address bidder) external view returns (Bid memory) {
        _getAuction(auctionId);
        return _bids[auctionId][bidder];
    }

    /// @notice 返回 18 位精度的美元估值；停用币种仍可查询。
    function quoteUsd(address token, uint256 amount) public view returns (uint256) {
        PriceConfig memory config = priceConfigs[token];
        if (config.feed == address(0)) revert UnsupportedToken(token);
        return Math.mulDiv(amount, _priceUsd18(config), DECIMAL_BASE ** uint256(config.tokenDecimals));
    }

    /// @param reservePriceUsd 18 位精度美元起拍价；首次出价可以等于起拍价。
    /// @param duration 拍卖时长，单位为秒，最大 30 天。
    function createAuction(address nftContract, uint256 tokenId, uint256 reservePriceUsd, uint256 duration)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 auctionId)
    {
        if (duration == 0 || duration > MAX_DURATION) revert InvalidDuration();
        if (nftContract.code.length == 0 || !IERC165(nftContract).supportsInterface(type(IERC721).interfaceId)) {
            revert InvalidNFT();
        }
        IERC721 nft = IERC721(nftContract);
        if (nft.ownerOf(tokenId) != msg.sender) revert Unauthorized();
        auctionId = ++auctionCount;
        uint256 endTime = block.timestamp + duration;
        _auctions[auctionId] = AuctionItem({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            reservePriceUsd: reservePriceUsd,
            highestBidUsd: 0,
            highestBidder: address(0),
            endTime: endTime,
            status: Status.Active,
            nftClaimed: false
        });

        // 只接收本次 createAuction 发起的转入，不接受无拍卖记录的 safeTransferFrom。
        _expectedNft = ExpectedNft({nftContract: nftContract, seller: msg.sender, tokenId: tokenId});
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        delete _expectedNft;
        if (nft.ownerOf(tokenId) != address(this)) revert InvalidNFT();
        // 对应资金/NFT 入口使用 nonReentrant；保留转账成功后发出事件的顺序。
        // forge-lint: disable-start(reentrancy-events)
        emit AuctionCreated(auctionId, msg.sender, nftContract, tokenId, reservePriceUsd, endTime);
        // forge-lint: disable-end(reentrancy-events)
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        ExpectedNft memory expected = _expectedNft;
        if (
            operator != address(this) || msg.sender != expected.nftContract || from != expected.seller
                || tokenId != expected.tokenId
        ) revert UnexpectedNFT();
        return this.onERC721Received.selector;
    }

    /// @notice 无人出价时卖家可取消；NFT 随后通过 claimNFT 领取。
    function cancelAuction(uint256 auctionId) external nonReentrant {
        AuctionItem storage auction = _getActiveAuction(auctionId);
        if (msg.sender != auction.seller) revert Unauthorized();
        if (auction.highestBidder != address(0)) revert AuctionHasBids();
        auction.status = Status.Cancelled;
        emit AuctionCancelled(auctionId);
    }

    /// @notice amount 为本次追加数量。同一账户退款前不能更换币种。
    function placeBid(uint256 auctionId, address token, uint256 amount) external payable nonReentrant whenNotPaused {
        AuctionItem storage auction = _getActiveAuction(auctionId);
        // 秒级截止时间/预言机新鲜度校验有意使用链上时间，不用于随机数。
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= auction.endTime) revert AuctionEnded(auctionId);
        if (msg.sender == auction.seller) revert SellerCannotBid();
        if (amount == 0 || (token == address(0) ? msg.value != amount : msg.value != 0)) revert InvalidAmount();
        if (!priceConfigs[token].enabled) {
            if (priceConfigs[token].feed == address(0)) {
                revert UnsupportedToken(token);
            }
            revert TokenDisabled(token);
        }
        Bid storage bid = _bids[auctionId][msg.sender];
        if (bid.amount != 0 && bid.token != token) revert BidTokenMismatch();
        uint256 totalAmount = bid.amount + amount;
        uint256 valueUsd = quoteUsd(token, totalAmount);
        if (
            valueUsd == 0
                || (auction.highestBidder == address(0)
                        ? valueUsd < auction.reservePriceUsd
                        : valueUsd <= auction.highestBidUsd)
        ) {
            revert BidTooLow(
                valueUsd, auction.highestBidder == address(0) ? auction.reservePriceUsd : auction.highestBidUsd
            );
        }

        // 所有价格、权限和竞价检查通过后才收款；拒绝转账税/不精确到账的代币。
        _collectPayment(token, amount);
        bid.token = token;
        bid.amount = totalAmount;
        auction.highestBidder = msg.sender;
        auction.highestBidUsd = valueUsd;
        totalLiabilities[token] += amount;
        // 对应资金/NFT 入口使用 nonReentrant；保留转账成功后发出事件的顺序。
        // forge-lint: disable-start(reentrancy-events)
        emit BidPlaced(auctionId, msg.sender, token, amount, totalAmount, valueUsd);
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @notice 非最高出价者可随时退款到指定地址，结算后仍然可退。
    function withdrawBid(uint256 auctionId, address recipient) external nonReentrant {
        AuctionItem storage auction = _getAuction(auctionId);
        _checkRecipient(recipient);
        if (auction.highestBidder == msg.sender && auction.status == Status.Active) revert HighestBidLocked();
        Bid storage bid = _bids[auctionId][msg.sender];
        uint256 amount = bid.amount;
        address token = bid.token;
        if (amount == 0) revert NothingToWithdraw();
        delete _bids[auctionId][msg.sender];
        _pay(token, recipient, amount);
        // 对应资金/NFT 入口使用 nonReentrant；保留转账成功后发出事件的顺序。
        // forge-lint: disable-start(reentrancy-events)
        emit BidWithdrawn(auctionId, msg.sender, token, recipient, amount);
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @notice 到期后任何人均可结算；不调用价格源、卖家或赢家，也不转出 NFT。
    function settleAuction(uint256 auctionId) external nonReentrant {
        _settle(auctionId, _getActiveAuction(auctionId));
    }

    /// @notice 赢家领取成交 NFT，卖家领取取消/流拍 NFT；可指定兼容 ERC721 的接收地址。
    /// @dev 尚未结算时可顺便结算；接收失败后也可单独调用 settleAuction，不阻塞卖家收入。
    // 保留现有 ABI 函数选择器及调用方使用的名称。
    // forge-lint: disable-next-line(mixed-case-function)
    function claimNFT(uint256 auctionId, address recipient) external nonReentrant {
        AuctionItem storage auction = _getAuction(auctionId);
        _checkRecipient(recipient);
        address claimant = auction.highestBidder == address(0) ? auction.seller : auction.highestBidder;
        if (msg.sender != claimant) revert Unauthorized();
        if (auction.nftClaimed) revert NFTAlreadyClaimed();
        if (auction.status == Status.Active) _settle(auctionId, auction);
        auction.nftClaimed = true;
        IERC721(auction.nftContract).safeTransferFrom(address(this), recipient, auction.tokenId);
        // 对应资金/NFT 入口使用 nonReentrant；保留转账成功后发出事件的顺序。
        // forge-lint: disable-start(reentrancy-events)
        emit NFTClaimed(auctionId, claimant, recipient);
        // forge-lint: disable-end(reentrancy-events)
    }

    function withdrawProceeds(address token, address recipient) external nonReentrant {
        _checkRecipient(recipient);
        uint256 amount = proceeds[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        proceeds[msg.sender][token] = 0;
        _pay(token, recipient, amount);
        // 对应资金/NFT 入口使用 nonReentrant；保留转账成功后发出事件的顺序。
        // forge-lint: disable-start(reentrancy-events)
        emit ProceedsWithdrawn(msg.sender, token, recipient, amount);
        // forge-lint: disable-end(reentrancy-events)
    }

    function _getAuction(uint256 auctionId) internal view returns (AuctionItem storage auction) {
        auction = _auctions[auctionId];
        if (auction.status == Status.None) revert AuctionNotFound(auctionId);
    }

    function _getActiveAuction(uint256 auctionId) internal view returns (AuctionItem storage auction) {
        auction = _getAuction(auctionId);
        if (auction.status != Status.Active) revert AuctionNotActive(auctionId);
    }

    function _settle(uint256 auctionId, AuctionItem storage auction) internal {
        // 秒级截止时间/预言机新鲜度校验有意使用链上时间，不用于随机数。
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < auction.endTime) {
            revert AuctionNotEnded(auctionId);
        }
        auction.status = Status.Settled;
        Bid memory winningBid = _bids[auctionId][auction.highestBidder];
        if (auction.highestBidder != address(0)) {
            delete _bids[auctionId][auction.highestBidder];
            proceeds[auction.seller][winningBid.token] += winningBid.amount;
        }
        emit AuctionSettled(
            auctionId, auction.seller, auction.highestBidder, winningBid.token, winningBid.amount, auction.highestBidUsd
        );
    }

    function _checkRecipient(address recipient) internal view {
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidAddress();
        }
    }

    function _priceUsd18(PriceConfig memory config) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(config.feed);
        // 估价仅使用 answer 和 updatedAt；其余轮次元数据不参与当前价格契约。
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        // 秒级截止时间/预言机新鲜度校验有意使用链上时间，不用于随机数。
        // forge-lint: disable-next-line(block-timestamp)
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) {
            revert InvalidPrice();
        }
        // 秒级截止时间/预言机新鲜度校验有意使用链上时间，不用于随机数。
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > config.maxAge) {
            revert StalePrice(updatedAt);
        }
        if (feed.decimals() != config.feedDecimals) revert InvalidPriceConfig();
        uint256 scale = DECIMAL_BASE ** uint256(USD_DECIMALS - config.feedDecimals);
        // 上方已拒绝 answer <= 0，同位宽转换不会丢失正值。
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 positiveAnswer = uint256(answer);
        if (positiveAnswer > type(uint256).max / scale) revert InvalidPrice();
        return positiveAnswer * scale;
    }

    function _collectPayment(address token, uint256 amount) internal {
        if (token == address(0)) return;
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = asset.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnexpectedTokenAmount();
    }

    // 调用者先清零各自余额；这里统一减少负债并转账。失败时整笔交易回滚。
    function _pay(address token, address recipient, uint256 amount) internal {
        totalLiabilities[token] -= amount;
        if (token == address(0)) {
            // 仅由 nonReentrant 提现入口调用；扣减调用者额度与总负债后支付，并检查成功状态。
            // forge-lint: disable-next-line(arbitrary-send-eth, low-level-calls)
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20 asset = IERC20(token);
            uint256 senderBefore = asset.balanceOf(address(this));
            uint256 recipientBefore = asset.balanceOf(recipient);
            asset.safeTransfer(recipient, amount);
            uint256 senderAfter = asset.balanceOf(address(this));
            uint256 recipientAfter = asset.balanceOf(recipient);
            // 这里如果有代币收转账手续费呢
            if (
                senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                    || recipientAfter - recipientBefore != amount
            ) {
                revert UnexpectedTokenAmount();
            }
        }
    }

    // 升级预留存储，保留名称、长度和位置。
    // forge-lint: disable-next-line(mixed-case-variable, unused-state-variables)
    uint256[41] private _gap;
}
