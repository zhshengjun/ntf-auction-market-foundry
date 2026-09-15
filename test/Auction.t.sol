// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
// 测试保留直观的金额常量，并将专用 mock 与用例放在一起。
// forge-lint: disable-start(literal-instead-of-constant, multi-contract-file)

import {Auction} from "../src/Auction.sol";
import {JunNFT} from "../src/JunNFT.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {Test} from "forge-std/Test.sol";

// 测试专用 V2 实现：用于验证 UUPS 升级后能增加新状态变量和新初始化逻辑。
contract AuctionTestV2 is Auction {
    uint256 public marker;

    function version() external pure returns (uint256) {
        return 2;
    }

    function initializeV2(uint256 value) external reinitializer(2) onlyOwner {
        marker = value;
    }
}

// 测试专用 ERC20：可以人为开启“每次转账扣固定手续费”，用来模拟 Fee-On-Transfer Token。
contract FeeOnTransferTestToken is ERC20 {
    uint256 public fee;
    constructor() ERC20("USD", "USD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 value) external {
        fee = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (fee != 0 && from != address(0) && to != address(0)) {
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

// 测试专用价格预言机：允许测试随时修改价格、更新时间和 decimals。
contract AuctionTestFeed {
    uint8 public decimals = 8;
    int256 public answer = 1e8;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(int256 value, uint256 timestamp) external {
        answer = value;
        updatedAt = timestamp;
    }

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

// 恶意测试 NFT：报告转账成功但不改变所有权，用于验证 Auction 的转入后所有权检查。
contract NonTransferringNFT is ERC721 {
    event TransferIgnored();

    constructor() ERC721("Broken NFT", "BROKEN") {
        _safeMint(msg.sender, 1);
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public override {
        emit TransferIgnored();
    }
}

// 恶意测试 Token：在 transferFrom 过程中回调 Auction.settleAuction，模拟 ERC20 重入攻击。
contract AuctionReentrantToken is FeeOnTransferTestToken {
    Auction public auction;
    uint256 public auctionId;
    bytes public failure;

    constructor(Auction target, uint256 id) {
        auction = target;
        auctionId = id;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        // 恶意回调测试：故意低级调用，随后检查失败状态并记录回滚数据。
        // forge-lint: disable-start(low-level-calls)
        (bool success, bytes memory result) = address(auction).call(abi.encodeCall(Auction.settleAuction, (auctionId)));
        // forge-lint: disable-end(low-level-calls)
        require(!success, "Reentry succeeded");
        failure = result;
        return super.transferFrom(from, to, value);
    }
}

// 恶意 ETH 接收方：收到 ETH 时立刻回调 Auction.placeBid，模拟 receive() 重入攻击。
contract AuctionReentrantRecipient {
    Auction public auction;
    uint256 public auctionId;
    bytes public failure;

    constructor(Auction target, uint256 id) {
        auction = target;
        auctionId = id;
    }

    receive() external payable {
        // 恶意回调测试：故意低级调用，随后检查失败状态并记录回滚数据。
        // forge-lint: disable-start(arbitrary-send-eth, low-level-calls)
        (bool success, bytes memory result) =
            address(auction).call{value: 1}(abi.encodeCall(Auction.placeBid, (auctionId, address(0), 1)));
        // forge-lint: disable-end(arbitrary-send-eth, low-level-calls)
        require(!success, "Reentry succeeded");
        failure = result;
    }
}

// 不实现 receive：测试合约作为卖家拒收 ETH，结算仍须成功。
contract AuctionTest is Test, ERC721Holder {
    // ========================================================================
    // Foundry 新手速查：
    // - vm.prank(A)       ：只让“紧接着的一次外部调用”的 msg.sender 变成 A。
    // - vm.startPrank(A)  ：从这里开始，后续调用持续模拟 A，直到 vm.stopPrank()。
    // - vm.expectRevert() ：声明“紧接着的下一次调用必须回滚”；下一次没回滚，测试就失败。
    // - vm.expectEmit(...)：声明接下来应发出符合条件的事件。
    // - vm.warp(t)        ：直接修改测试链的 block.timestamp。
    // - vm.deal(A, x)     ：直接给地址 A 设置 ETH 余额（仅测试环境）。
    // - assertEq(a, b)    ：断言 a == b；不相等则测试失败。
    // - assertTrue(x)     ：断言 x == true。
    // - assertFalse(x)    ：断言 x == false。
    // ========================================================================
    Auction auction;
    JunNFT nft;
    // Circle 官方 Ethereum Sepolia USDC；仅在本地分叉上操作。
    IERC20Metadata token;
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    AuctionTestFeed feed;
    address bidder = address(0xB1);
    address other = address(0xB2);
    uint256 id;

    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed winner,
        address token,
        uint256 amount,
        uint256 valueUsd
    );

    // ========================================================================
    // setUp：每个 test_* 测试执行前，Foundry 都会重新执行一次这里。
    // 目的：为每个测试创建完全独立、可重复的初始环境。
    // 主要步骤：
    // 1. 固定区块时间；
    // 2. 通过 ERC1967Proxy 部署 Auction 和 JunNFT；
    // 3. 配置 ETH / USDC 的价格预言机；
    // 4. 默认创建 1 个拍卖；
    // 5. 给 bidder / other 准备 ETH、USDC，并提前 approve。
    // ========================================================================
    function setUp() public {
        // 1. 创建并切换到 Sepolia fork
        uint256 forkId = vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        assertEq(vm.activeFork(), forkId);
        // 测试专用：直接修改当前区块时间，不需要真实等待。
        vm.warp(100_000);
        auction = Auction(
            address(new ERC1967Proxy(address(new Auction()), abi.encodeCall(Auction.initialize, (address(this)))))
        );
        nft = JunNFT(
            address(new ERC1967Proxy(address(new JunNFT()), abi.encodeCall(JunNFT.initialize, (100, address(this)))))
        );
        token = IERC20Metadata(SEPOLIA_USDC);
        require(address(token).code.length > 0, "Run tests on the configured Sepolia fork");
        feed = new AuctionTestFeed();
        auction.configureToken(address(0), address(feed), 1 hours);
        auction.configureToken(address(token), address(feed), 1 hours);
        id = _create(0, 1 hours);
        // 测试专用：直接设置该地址的 ETH 余额。
        vm.deal(bidder, 100 ether);
        // 测试专用：直接设置该地址的 ETH 余额。
        vm.deal(other, 100 ether);
        // 只设置本地分叉余额；不调用真实 USDC 的铸币权限或向测试网发送交易。
        // 测试专用：直接设置该地址的 ERC20 余额，不会调用真实 USDC 的 mint。
        deal(address(token), bidder, 100e6);
        // 测试专用：直接设置该地址的 ERC20 余额，不会调用真实 USDC 的 mint。
        deal(address(token), other, 100e6);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 授权 Auction 合约可以从该地址转走对应 ERC20 / NFT。
        assertTrue(token.approve(address(auction), type(uint256).max), "ERC20 approval failed");
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        // 授权 Auction 合约可以从该地址转走对应 ERC20 / NFT。
        assertTrue(token.approve(address(auction), type(uint256).max), "ERC20 approval failed");
    }

    // 辅助函数：创建一场新的 NFT 拍卖。
    // 流程：mint NFT -> 找到新 tokenId -> 授权 Auction -> createAuction。
    // 返回值就是新创建的 auctionId，方便测试继续操作。
    function _create(uint256 reserve, uint256 duration) internal returns (uint256) {
        // 测试夹具操作本地部署的合约；后续 id 更新用于编排独立测试场景。
        // forge-lint: disable-next-line(reentrancy-no-eth)
        nft.mint(address(this));
        uint256 tokenId = nft.tokenOfOwnerByIndex(address(this), nft.balanceOf(address(this)) - 1);
        // 授权 Auction 合约可以从该地址转走对应 ERC20 / NFT。
        // 测试夹具操作本地部署的合约；后续 id 更新用于编排独立测试场景。
        // forge-lint: disable-next-line(reentrancy-no-eth)
        nft.approve(address(auction), tokenId);
        // 测试夹具操作本地部署的合约；后续 id 更新用于编排独立测试场景。
        // forge-lint: disable-next-line(reentrancy-no-eth)
        return auction.createAuction(address(nft), tokenId, reserve, duration);
    }

    // 辅助函数：让指定地址 who 使用 ETH 对当前 id 拍卖出价。
    // vm.prank(who) 会让紧接着的 placeBid 看起来像是 who 发起的。
    function _bid(address who, uint256 amount) internal {
        // 下一次外部调用模拟由 who 发起，也就是下一次调用里的 msg.sender = who。
        vm.prank(who);
        // 测试向 setUp 创建的拍卖代理发送 ETH，验证出价或预期回滚。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        auction.placeBid{value: amount}(id, address(0), amount);
    }

    // 辅助函数：把区块时间直接推进到当前拍卖的 endTime。
    // 这样无需真实等待，就可以测试“拍卖结束后”的逻辑。
    function _end() internal {
        // 测试专用：直接修改当前区块时间，不需要真实等待。
        // 测试夹具操作本地部署的合约；后续 id 更新用于编排独立测试场景。
        // forge-lint: disable-next-line(reentrancy-no-eth)
        vm.warp(auction.getAuction(id).endTime);
    }

    // 【测试目标】正常创建拍卖后，各项初始状态是否正确。
    // 重点验证：auctionId、卖家、tokenId、状态、NFT 托管关系、NFT 元数据、初始出价。
    function test_CreationAndQueries() public view {
        Auction.AuctionItem memory item = auction.getAuction(id);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(id, 1);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.auctionCount(), 1);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(item.seller, address(this));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(item.tokenId, 1);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(uint256(item.status), uint256(Auction.Status.Active));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(1), address(auction));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.owner(), address(this));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.name(), "JunNFT");
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.totalSupply(), 1);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.tokenOfOwnerByIndex(address(auction), 0), 1);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(id, bidder).amount, 0);
    }

    // 【测试目标】创建拍卖时的参数校验和权限校验。
    // 依次测试：duration 非法、NFT 地址非法、调用者不是 NFT 所有人、未授权 Auction。
    // 最后确认所有失败操作都没有新增拍卖，也没有把 NFT 转走。
    function test_CreationRejectsInvalidInputsAndMissingApproval() public {
        nft.mint(address(this));
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidDuration.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.createAuction(address(nft), 2, 0, 0);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidDuration.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.createAuction(address(nft), 2, 0, 30 days + 1);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidNFT.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.createAuction(bidder, 2, 0, 1 hours);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.Unauthorized.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.createAuction(address(nft), 2, 0, 1 hours);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert();
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.createAuction(address(nft), 2, 0, 1 hours);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.auctionCount(), 1);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(2), address(this));
    }

    // 【测试目标】Auction 不能被别人“硬塞”一个并非 createAuction 流程中的 NFT。
    // 第一部分：直接 safeTransferFrom 给 Auction，应触发 UnexpectedNFT 并整体回滚。
    // 第二部分：测试代码主动调用 onERC721Received，是为了单独验证这个回调入口本身也有保护。
    // 注意：真实 safeTransferFrom 时 onERC721Received 通常是 ERC721 合约自动回调；
    //      这里主动调用不是正常业务流程，而是在做“入口级单元测试”。
    // 两个 expectRevert 分别对应两个不同的“下一次调用”，所以需要写两遍。
    function test_UnsolicitedSafeNFTTransferRejected() public {
        nft.mint(address(this));
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.UnexpectedNFT.selector);
        nft.safeTransferFrom(address(this), address(auction), 2);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(2), address(this));
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.UnexpectedNFT.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.onERC721Received(address(auction), address(this), 1, "");
    }

    // 【测试目标】首笔出价可以刚好等于保留价，但后续最高价必须严格提高。
    // 同一个 bidder 可以再次加价；测试最后检查累计出价和折算后的最高美元价值。
    function test_FirstBidCanEqualReserveButSubsequentBidMustExceed() public {
        id = _create(1e18, 1 hours);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.BidTooLow.selector, 0.5e18, 1e18));
        // 测试向 setUp 创建的拍卖代理发送 ETH，验证出价或预期回滚。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        auction.placeBid{value: 0.5 ether}(id, address(0), 0.5 ether);
        _bid(bidder, 1 ether);
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.BidTooLow.selector, 1e18, 1e18));
        // 测试向 setUp 创建的拍卖代理发送 ETH，验证出价或预期回滚。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        auction.placeBid{value: 1 ether}(id, address(0), 1 ether);
        _bid(bidder, 1 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(id, bidder).amount, 2 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getAuction(id).highestBidUsd, 2e18);
    }

    // 【测试目标】ETH 拍卖结算采用“记账 + 主动领取”模式，而不是结算时直接给卖家/NFT 买家转账。
    // 验证事件、卖家 proceeds、winner 的 bid 清零、总负债，以及之后提现和领取 NFT 的结果。
    function test_ETHSettlementDoesNotCallEitherParty() public {
        _bid(bidder, 1 ether);
        _end();
        // 预期下一次相关调用会发出指定事件；后面的 emit 是“期望模板”，不是实际再次执行业务事件。
        vm.expectEmit(true, true, true, true, address(auction));
        // expectEmit 的期望事件模板，不是生产合约的外部调用后事件。
        // forge-lint: disable-start(reentrancy-events)
        emit AuctionSettled(id, address(this), bidder, address(0), 1 ether, 1e18);
        // forge-lint: disable-end(reentrancy-events)
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(1), address(auction));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.proceeds(address(this), address(0)), 1 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(id, bidder).amount, 0);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 1 ether);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), other);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(other.balance, 101 ether);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(1), bidder);
        // 断言：该布尔条件最终必须为 true。
        assertTrue(auction.getAuction(id).nftClaimed);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.balanceOf(address(auction)), 0);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.tokenOfOwnerByIndex(bidder, 0), 1);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 0);
    }

    // 【测试目标】同一拍卖允许不同竞拍者使用不同币种比较美元价值，并正确退款/结算。
    // bidder 用 ETH，other 用 USDC；最终确认败者退款、卖家收款、赢家领取 NFT、合约负债归零。
    function test_ERC20WinnerAndMixedCurrencyRefund() public {
        _bid(bidder, 1 ether);
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        auction.placeBid(id, address(token), 2e6);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, bidder);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(token), other);
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(bidder.balance, 100 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(token.balanceOf(other), 100e6);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(1), bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(token)), 0);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(address(auction).balance, 0);
    }

    // 【测试目标】取消拍卖和无人出价结束的拍卖，NFT 都可以被正确领取。
    // 同时验证取消后的状态，以及未售出拍卖结算后的 NFT 处理。
    function test_UnsoldAndCancelledNFTClaims() public {
        // 测试夹具操作本地部署的合约；后续 id 更新用于编排独立测试场景。
        // forge-lint: disable-next-line(reentrancy-no-eth)
        auction.cancelAuction(id);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(uint256(auction.getAuction(id).status), uint256(Auction.Status.Cancelled));
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        // 测试夹具操作本地部署的合约；后续 id 更新用于编排独立测试场景。
        // forge-lint: disable-next-line(reentrancy-no-eth)
        auction.claimNFT(id, bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(1), bidder);
        id = _create(0, 1 hours);
        _end();
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, other);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(2), other);
    }

    // 【测试目标】只有卖家可以取消，而且一旦已经有人出价就不能取消。
    // 分别验证 Unauthorized 和 AuctionHasBids 两个错误分支。
    function test_CancellationRejectsNonSellerAndExistingBids() public {
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.Unauthorized.selector);
        auction.cancelAuction(id);
        _bid(bidder, 1 ether);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.AuctionHasBids.selector);
        auction.cancelAuction(id);
    }

    // 【测试目标】败标者的退款可以指定另一个 recipient，但只能提取自己的退款额度。
    // 提现后再次提取应 NothingToWithdraw；同时验证剩余负债只包含赢家资金。
    function test_RefundCanUseDifferentRecipientAfterSettlement() public {
        _bid(bidder, 1 ether);
        _bid(other, 2 ether);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, other);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(other.balance, 99 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 2 ether);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.NothingToWithdraw.selector);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, bidder);
    }

    // 【测试目标】当前最高出价在结算前被锁定；如果最终胜出，结算后也不能再按退款取回。
    // 这是防止赢家既拿 NFT 又拿回竞拍资金。
    function test_HighestBidLockedUntilSettledAndNeverRefundedAfterWin() public {
        _bid(bidder, 1 ether);
        _end();
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.HighestBidLocked.selector);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, bidder);
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.NothingToWithdraw.selector);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, bidder);
    }

    // 【测试目标】卖家提现 ETH 失败时，内部记账不能丢失。
    // 先故意提现到不接收 ETH 的测试合约，确认失败后 proceeds / liabilities 仍保留；
    // 再提现到正常地址，最后确认不能重复提现。
    function test_FailedWithdrawalPreservesCreditAndLiability() public {
        _bid(bidder, 1 ether);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.ETHTransferFailed.selector);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), address(this));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.proceeds(address(this), address(0)), 1 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 1 ether);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.NothingToWithdraw.selector);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), bidder);
    }

    // 【测试目标】NFT 领取失败不能破坏拍卖的其它结算流程。
    // 先向不能接收 NFT 的地址领取并失败，再完成 settlement / proceeds 提现，最后改用正常地址领取。
    function test_FailedNFTClaimDoesNotBlockIndependentSettlement() public {
        _bid(bidder, 1 ether);
        _end();
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert();
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, address(feed));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(uint256(auction.getAuction(id).status), uint256(Auction.Status.Active));
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), other);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert();
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, address(feed));
        // 断言：该布尔条件最终必须为 false。
        assertFalse(auction.getAuction(id).nftClaimed);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, bidder);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.NFTAlreadyClaimed.selector);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, bidder);
    }

    // 【测试目标】只有有资格领取 NFT 的人，才可以决定 NFT 发往哪个 recipient。
    // 同时拒绝把 NFT 发给 Auction 合约自身等非法地址。
    function test_OnlyClaimantCanChooseNFTRecipient() public {
        _bid(bidder, 1 ether);
        _end();
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.Unauthorized.selector);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, other);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidAddress.selector);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, address(auction));
    }

    // 【测试目标】pause 只阻止新增风险敞口（新出价/新拍卖），不能阻止用户退出资金或完成已有头寸结算。
    // 这是常见的安全设计：紧急暂停时用户仍应能退款、结算、领取 NFT、提现。
    function test_PauseBlocksExposureButNotExit() public {
        _bid(bidder, 1 ether);
        _bid(other, 2 ether);
        auction.pause();
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        // 测试向 setUp 创建的拍卖代理发送 ETH，验证出价或预期回滚。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        auction.placeBid{value: 3 ether}(id, address(0), 3 ether);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.createAuction(address(nft), 1, 0, 1 hours);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, bidder);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, other);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 0);
        auction.unpause();
        // 断言：该布尔条件最终必须为 false。
        assertFalse(auction.paused());
    }

    // 【测试目标】管理员禁用某 ERC20 后，不能再用它新增出价，但已有资金仍可以正常结算和提现。
    function test_TokenDisableDoesNotBlockExits() public {
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        auction.placeBid(id, address(token), 1e6);
        auction.setTokenEnabled(address(token), false);
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.TokenDisabled.selector, address(token)));
        auction.placeBid(id, address(token), 2e6);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(token), other);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(token.balanceOf(other), 101e6);
    }

    // 【测试目标】价格预言机的数值、时间戳、精度(decimal)检查是否正确，并验证金额统一换算到 18 位 USD 精度。
    // 覆盖：正常报价、0/负价格、时间戳为 0、未来时间、过期价格、非法 feed decimals。
    function test_PriceChecksAndDecimalNormalization() public {
        feed.set(2000e8, block.timestamp);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.quoteUsd(address(0), 0.5 ether), 1000e18);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.quoteUsd(address(0), 1), 2000);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.quoteUsd(address(token), 1e6), 2000e18);
        feed.set(0, block.timestamp);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPrice.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(0), 1 ether);
        feed.set(-1, block.timestamp);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPrice.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(0), 1 ether);
        feed.set(1e8, 0);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPrice.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(0), 1 ether);
        feed.set(1e8, block.timestamp + 1);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPrice.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(0), 1 ether);
        feed.set(1e8, block.timestamp - 1 hours - 1);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.StalePrice.selector, block.timestamp - 1 hours - 1));
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(0), 1 ether);
        feed.set(1e8, block.timestamp);
        feed.setDecimals(18);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPriceConfig.selector);
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(0), 1 ether);
    }

    // 【测试目标】竞拍时记录好的结果不应因为后来预言机坏掉而无法退出。
    // 先正常出价，再把 oracle 改成非法值；结算和卖家提现仍应成功。
    function test_BadOracleDoesNotAffectSettlementAndWithdrawals() public {
        _bid(bidder, 1 ether);
        feed.set(-1, 0);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(bidder.balance, 100 ether);
    }

    // 【测试目标】拒绝“转账扣税型 ERC20”作为入金，避免用户声明转 1e6 但合约实际收到更少。
    // 失败后检查 ERC20 余额、总负债、最高出价者均恢复原状，证明整笔交易回滚。
    function test_RejectsFeeOnTransferDepositsAndRollsBack() public {
        FeeOnTransferTestToken feeToken = new FeeOnTransferTestToken();
        auction.configureToken(address(feeToken), address(feed), 1 hours);
        feeToken.mint(bidder, 100e6);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 授权 Auction 合约可以从该地址转走对应 ERC20 / NFT。
        assertTrue(feeToken.approve(address(auction), type(uint256).max), "ERC20 approval failed");
        feeToken.setFee(1);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.UnexpectedTokenAmount.selector);
        auction.placeBid(id, address(feeToken), 1e6);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(feeToken.balanceOf(bidder), 100e6);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(feeToken)), 0);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getAuction(id).highestBidder, address(0));
    }

    // 【测试目标】如果 ERC20 在提现阶段突然开始收转账税，Auction 应拒绝该次提现且保留用户记账额度。
    // 关闭手续费后再次提现应成功。
    function test_RejectsOutgoingTransferTaxWithoutLosingCredit() public {
        FeeOnTransferTestToken feeToken = new FeeOnTransferTestToken();
        auction.configureToken(address(feeToken), address(feed), 1 hours);
        feeToken.mint(bidder, 100e6);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 授权 Auction 合约可以从该地址转走对应 ERC20 / NFT。
        assertTrue(feeToken.approve(address(auction), type(uint256).max), "ERC20 approval failed");
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        auction.placeBid(id, address(feeToken), 1e6);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        feeToken.setFee(1);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.UnexpectedTokenAmount.selector);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(feeToken), other);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.proceeds(address(this), address(feeToken)), 1e6);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(feeToken)), 1e6);
        feeToken.setFee(0);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(feeToken), other);
    }

    // 【测试目标】综合检查出价参数：卖家不能竞拍、msg.value 与 amount 必须匹配、ERC20 出价不能夹带 ETH、币种必须受支持。
    // 同一竞拍者有未退款的旧出价时不能切换币种；退款后才允许重新用另一币种出价。
    function test_BidValidationAndTokenSwitchAfterRefund() public {
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.SellerCannotBid.selector);
        auction.placeBid(id, address(0), 0);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidAmount.selector);
        // 测试向 setUp 创建的拍卖代理发送 ETH，验证出价或预期回滚。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        auction.placeBid{value: 1 ether}(id, address(0), 2 ether);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidAmount.selector);
        // 测试向 setUp 创建的拍卖代理发送 ETH，验证出价或预期回滚。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        auction.placeBid{value: 1}(id, address(token), 1e6);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.UnsupportedToken.selector, other));
        auction.placeBid(id, other, 1);
        _bid(bidder, 1 ether);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.BidTokenMismatch.selector);
        auction.placeBid(id, address(token), 2e6);
        _bid(other, 2 ether);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, bidder);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        auction.placeBid(id, address(token), 3e6);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(id, bidder).token, address(token));
    }

    // 【测试目标】拍卖时间边界和重复结算保护。
    // 结束前不能 settle；结束后不能继续 bid；settle 后不能再次 settle；不存在的 auctionId 也必须报错。
    function test_TimeBoundariesAndRepeatedSettlement() public {
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.AuctionNotEnded.selector, id));
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        _end();
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.AuctionEnded.selector, id));
        // 测试向 setUp 创建的拍卖代理发送 ETH，验证出价或预期回滚。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        auction.placeBid{value: 1 ether}(id, address(0), 1 ether);
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.AuctionNotActive.selector, id));
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.AuctionNotFound.selector, 0));
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.getAuction(0);
    }

    // 【测试目标】管理员权限以及 Ownable2Step 两步所有权转移。
    // 非 owner 不能 pause/config；禁止 renounce；transferOwnership 后旧 owner 暂时仍是 owner，必须由 pending owner accept。
    function test_AdminPermissionsAndTwoStepTransfer() public {
        // 从这里开始连续模拟 bidder 调用，直到 vm.stopPrank()。
        vm.startPrank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bidder));
        auction.pause();
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bidder));
        auction.configureToken(other, address(feed), 1 hours);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bidder));
        auction.setTokenEnabled(address(0), false);
        // 结束连续身份模拟，后续调用恢复为测试合约自身发起。
        vm.stopPrank();
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.OwnershipRequired.selector);
        auction.renounceOwnership();
        auction.transferOwnership(other);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.owner(), address(this));
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bidder));
        auction.acceptOwnership();
        // 下一次外部调用模拟由 other 发起，也就是下一次调用里的 msg.sender = other。
        vm.prank(other);
        auction.acceptOwnership();
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.owner(), other);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        auction.pause();
    }

    // 【测试目标】更新 token 价格配置时使用新的 feed / decimals / maxAge，但保留原先 disabled 状态。
    // 最后 quoteUsd 用新价格验证配置确实生效。
    function test_ConfigUpdatePreservesDisabledStateAndUsesNewFeed() public {
        AuctionTestFeed replacement = new AuctionTestFeed();
        replacement.setDecimals(6);
        replacement.set(2e6, block.timestamp);
        auction.setTokenEnabled(address(token), false);
        auction.configureToken(address(token), address(replacement), 2 hours);
        (address configuredFeed, uint8 tokenDecimals, uint8 feedDecimals, bool enabled, uint256 maxAge) =
            auction.priceConfigs(address(token));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(configuredFeed, address(replacement));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(tokenDecimals, 6);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(feedDecimals, 6);
        // 断言：该布尔条件最终必须为 false。
        assertFalse(enabled);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(maxAge, 2 hours);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.quoteUsd(address(token), 1e6), 2e18);
    }

    // 【测试目标】调整 maxAge / 更换 feed 只影响未来报价，不能追溯修改已经记录的历史出价美元价值。
    // 随后新的出价使用新 feed 价格参与比较，并检查最终 proceeds / liabilities。
    function test_MaxAgeUpdateRestoresQuoteWithoutChangingExistingBid() public {
        _bid(bidder, 1 ether);
        feed.set(1e8, block.timestamp - 1 hours - 1);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.StalePrice.selector, feed.updatedAt()));
        // 该调用由 expectRevert 验证回滚，不检查成功路径的返回值。
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(0), 1 ether);
        auction.configureToken(address(0), address(feed), 2 hours);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.quoteUsd(address(0), 1 ether), 1e18);
        AuctionTestFeed replacement = new AuctionTestFeed();
        replacement.set(2e8, block.timestamp);
        auction.configureToken(address(0), address(replacement), 1 hours);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getAuction(id).highestBidUsd, 1e18);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(id, bidder).amount, 1 ether);
        _bid(other, 0.75 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getAuction(id).highestBidUsd, 1.5e18);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 1.75 ether);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.proceeds(address(this), address(0)), 0.75 ether);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(bidder.balance, 100 ether);
    }

    // 【测试目标】非法配置更新必须整体回滚，旧配置保持不变。
    // 覆盖坏价格、maxAge=0、feed 不是合约、不支持的 token、token decimals 不符合要求。
    function test_InvalidConfigUpdateLeavesPreviousConfigIntact() public {
        AuctionTestFeed replacement = new AuctionTestFeed();
        replacement.set(0, block.timestamp);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPrice.selector);
        auction.configureToken(address(0), address(replacement), 2 hours);
        (address configuredFeed, uint8 tokenDecimals, uint8 feedDecimals, bool enabled, uint256 maxAge) =
            auction.priceConfigs(address(0));
        assertEq(tokenDecimals, 18);
        assertEq(feedDecimals, 8);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(configuredFeed, address(feed));
        // 断言：该布尔条件最终必须为 true。
        assertTrue(enabled);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(maxAge, 1 hours);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPriceConfig.selector);
        auction.configureToken(address(0), address(feed), 0);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPriceConfig.selector);
        auction.configureToken(address(0), other, 1 hours);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.UnsupportedToken.selector, other));
        auction.configureToken(other, address(feed), 1 hours);
        vm.mockCall(address(token), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidPriceConfig.selector);
        auction.configureToken(address(token), address(feed), 1 hours);
    }

    // 【测试目标】只有 owner 才能修改已有的价格配置。
    function test_OnlyOwnerCanUpdateExistingPriceConfig() public {
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bidder));
        auction.configureToken(address(0), address(feed), 2 hours);
    }

    // 【测试目标】ETH 退款过程中，恶意 recipient 的 receive() 尝试重入 placeBid 必须被 ReentrancyGuard 拦截。
    // 同时确认正常退款仍到账，且其它资金负债没有被破坏。
    function test_ReentrantETHRecipientCannotPlaceBidDuringPayment() public {
        _bid(bidder, 1 ether);
        _bid(other, 2 ether);
        AuctionReentrantRecipient recipient = new AuctionReentrantRecipient(auction, id);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, address(recipient));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(recipient.failure(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(address(recipient).balance, 1 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 2 ether);
    }

    // 【测试目标】恶意 ERC20 在 transferFrom 入金过程中尝试重入 settleAuction 必须失败。
    // 验证被攻击的旧拍卖仍保持 Active，新拍卖入金记账仍正确。
    function test_ReentrantTokenCannotSettleAnotherAuctionDuringDeposit() public {
        _end();
        uint256 expiredId = id;
        id = _create(0, 1 hours);
        feed.set(1e8, block.timestamp);
        AuctionReentrantToken malicious = new AuctionReentrantToken(auction, expiredId);
        auction.configureToken(address(malicious), address(feed), 1 hours);
        malicious.mint(bidder, 1e6);
        // 从这里开始连续模拟 bidder 调用，直到 vm.stopPrank()。
        vm.startPrank(bidder);
        // 授权 Auction 合约可以从该地址转走对应 ERC20 / NFT。
        assertTrue(malicious.approve(address(auction), 1e6), "ERC20 approval failed");
        auction.placeBid(id, address(malicious), 1e6);
        // 结束连续身份模拟，后续调用恢复为测试合约自身发起。
        vm.stopPrank();
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(malicious.failure(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(uint256(auction.getAuction(expiredId).status), uint256(Auction.Status.Active));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(malicious)), 1e6);
    }

    // 【测试目标】不同 auctionId 的出价记录彼此隔离，但同一卖家最终收益可以按币种聚合。
    // 两场拍卖各自 1 ETH / 2 ETH，结算后卖家 proceeds 应为 3 ETH。
    function test_AuctionsKeepBidsSeparateAndAggregateSellerProceeds() public {
        uint256 secondId = _create(0, 1 hours);
        _bid(bidder, 1 ether);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 测试向 setUp 创建的拍卖代理发送 ETH，验证出价或预期回滚。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        auction.placeBid{value: 2 ether}(secondId, address(0), 2 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(id, bidder).amount, 1 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(secondId, bidder).amount, 2 ether);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(secondId);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.proceeds(address(this), address(0)), 3 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 3 ether);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), other);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 0);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(address(auction).balance, 0);
    }

    // 【测试目标】预言机过期时必须在转走 ERC20 之前失败；0 金额出价也必须拒绝。
    // 通过余额断言确认失败出价没有产生任何资金移动。
    function test_StaleBidFailsBeforeMovingERC20AndZeroBidRejected() public {
        feed.set(1e8, block.timestamp - 1 hours - 1);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSelector(Auction.StalePrice.selector, block.timestamp - 1 hours - 1));
        auction.placeBid(id, address(token), 1e6);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(token.balanceOf(bidder), 100e6);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(token.balanceOf(address(auction)), 0);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.placeBid(id, address(0), 0);
    }

    // 【测试目标】退款 recipient 非法时，提现失败不能把竞拍者的退款额度“吃掉”。
    // 最后检查原 bid 金额和合约总负债仍完整保留。
    function test_InvalidRefundRecipientsCannotDestroyCredit() public {
        _bid(bidder, 1 ether);
        _bid(other, 2 ether);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidAddress.selector);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, address(0));
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidAddress.selector);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, address(auction));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(id, bidder).amount, 1 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 3 ether);
    }

    // 【测试目标】UUPS 可升级合约的初始化、升级权限、实现合约合法性以及升级后的状态保持。
    // 验证：implementation 不能初始化、proxy 不能重复 initialize、非 owner 不能升级、不能升级到非 UUPS 实现；
    // 正常升级到 V2 后 version/marker 生效，而且 owner、bid、liabilities 等旧状态都保留。
    function test_UUPSInitializationAndUpgradePreserveState() public {
        Auction implementation = new Auction();
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        implementation.initialize(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        auction.initialize(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(Auction.InvalidAddress.selector);
        new ERC1967Proxy(address(implementation), abi.encodeCall(Auction.initialize, (address(0))));
        _bid(bidder, 1 ether);
        AuctionTestV2 next = new AuctionTestV2();
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bidder));
        // UUPS 升级入口：切换实现合约，并可在同一交易中执行 V2 初始化调用。
        auction.upgradeToAndCall(address(next), bytes(""));
        // 预期“紧接着的下一次调用”必须回滚；如果下一次调用成功，测试反而会失败。
        vm.expectRevert(abi.encodeWithSignature("ERC1967InvalidImplementation(address)", address(feed)));
        // UUPS 升级入口：切换实现合约，并可在同一交易中执行 V2 初始化调用。
        auction.upgradeToAndCall(address(feed), bytes(""));
        // UUPS 升级入口：切换实现合约，并可在同一交易中执行 V2 初始化调用。
        auction.upgradeToAndCall(address(next), abi.encodeCall(AuctionTestV2.initializeV2, (42)));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(AuctionTestV2(address(auction)).version(), 2);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(AuctionTestV2(address(auction)).marker(), 42);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.owner(), address(this));
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.getBid(id, bidder).amount, 1 ether);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 1 ether);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), bidder);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 领取拍卖对应的 NFT；recipient 可以与调用者不同，但调用者必须有领取资格。
        auction.claimNFT(id, other);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(nft.ownerOf(1), other);
    }

    // 【测试目标】覆盖剩余的币种配置和价格保护分支。
    function test_RemainingPriceValidationBranches() public {
        vm.expectRevert(abi.encodeWithSelector(Auction.UnsupportedToken.selector, address(1)));
        auction.setTokenEnabled(address(1), true);

        vm.expectRevert(abi.encodeWithSelector(Auction.UnsupportedToken.selector, address(1)));
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(1), 1);

        AuctionTestFeed replacement = new AuctionTestFeed();
        replacement.setDecimals(19);
        vm.expectRevert(Auction.InvalidPriceConfig.selector);
        auction.configureToken(address(0), address(replacement), 1 hours);

        replacement.setDecimals(0);
        replacement.set(1, block.timestamp);
        auction.configureToken(address(0), address(replacement), 1 hours);
        replacement.set(type(int256).max, block.timestamp);
        vm.expectRevert(Auction.InvalidPrice.selector);
        // forge-lint: disable-next-line(unused-return)
        auction.quoteUsd(address(0), 1 ether);
    }

    // 【测试目标】ERC721 声称转账成功但所有权未变化时，创建拍卖必须回滚。
    function test_CreateAuctionRejectsNFTThatDoesNotTransfer() public {
        NonTransferringNFT brokenNft = new NonTransferringNFT();

        vm.expectRevert(Auction.InvalidNFT.selector);
        // forge-lint: disable-next-line(unused-return)
        auction.createAuction(address(brokenNft), 1, 0, 1 hours);
    }

    // 【测试目标】JunNFT owner 可以执行 UUPS 升级，升级后原有铸造行为正常。
    function test_JunNFTOwnerCanUpgrade() public {
        nft.upgradeToAndCall(address(new JunNFT()), bytes(""));
        nft.mint(address(1));
        assertEq(nft.ownerOf(2), address(1));
    }

    // 【测试目标】部署脚本创建并正确初始化 Auction 与 JunNFT 代理。
    function test_DeployRunCreatesInitializedProxies() public {
        address initialOwner = address(0xA11CE);
        // 测试部署脚本需要提供脚本读取的环境变量。
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("INITIAL_OWNER", vm.toString(initialOwner));

        (address auctionProxy, address nftProxy) = new Deploy().run();

        assertEq(Auction(auctionProxy).owner(), initialOwner);
        assertEq(JunNFT(nftProxy).owner(), initialOwner);
    }

    // 【Fuzz 测试目标】让 Foundry 自动生成大量 first/extra 输入，检查资金守恒性质。
    // 不关心某一个固定金额，而是验证一大批合法出价下：合约余额与 liabilities 始终一致，最终全部退出后都归零。
    function test_FuzzLiabilitiesConservedAcrossRefundAndSettlement(uint96 first, uint96 extra) public {
        // bound() 把 fuzz 随机输入限制到合理范围，避免 0、溢出或无意义的极端值。
        uint256 a = bound(uint256(first), 1, 10 ether);
        // bound() 把 fuzz 随机输入限制到合理范围，避免 0、溢出或无意义的极端值。
        uint256 b = a + bound(uint256(extra), 1, 10 ether);
        _bid(bidder, a);
        _bid(other, b);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), a + b);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(address(auction).balance, a + b);
        _end();
        // 执行拍卖结算：确定最终结果并把应付款/退款记入内部账本。
        auction.settleAuction(id);
        // 下一次外部调用模拟由 bidder 发起，也就是下一次调用里的 msg.sender = bidder。
        vm.prank(bidder);
        // 提取可退款的竞拍资金；正常情况下只能提取自己的可退款额度。
        auction.withdrawBid(id, bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), b);
        // 卖家提取已经记账的成交收益。
        auction.withdrawProceeds(address(0), bidder);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(auction.totalLiabilities(address(0)), 0);
        // 断言：这里读取到的实际值必须等于期望值，否则说明状态变化不符合设计。
        assertEq(address(auction).balance, 0);
    }

    // 【测试目标】最小化验证 JunNFT 的 mint -> 查 tokenId -> burn 流程可以正常执行。
    // 该测试当前没有额外 assert；如果 burn() 不回滚，则测试通过。
    function test_burnNFT() public {
        nft.mint(address(this));
        uint256 tokenId = nft.tokenOfOwnerByIndex(address(this), nft.balanceOf(address(this)) - 1);
        nft.burn(tokenId);
    }
}
