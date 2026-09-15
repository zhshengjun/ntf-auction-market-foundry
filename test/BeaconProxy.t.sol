// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract Logic1 {
    string constant BEACONLOGIC = "beacon logic contract 1";

    function get() external pure returns (string memory) {
        return BEACONLOGIC;
    }
}

contract Logic2 {
    string constant BEACONLOGIC = "beacon logic contract 2";

    function get() external pure returns (string memory) {
        return BEACONLOGIC;
    }
}


contract BeaconProxyTest is Test {
    UpgradeableBeacon public beacon;
    BeaconProxy public proxy;
    address public owner;

    Logic1 public logic1;
    Logic2 public logic2;

    function setUp() public {
        owner = address(this);
        // 部署初始逻辑合约
        logic1 = new Logic1();
        // 部署信标
        beacon = new UpgradeableBeacon(address(logic1),address(this));
        // 编码初始化调用（可选）
        bytes memory data = abi.encodeWithSignature("get()");
        // 部署代理
        proxy = new BeaconProxy(address(beacon), data);
    }

    //  测试代理调用
    function test_CallGetThroughProxy() public {
        // 通过代理合约调用 get()，应该返回 logic1 的内容
        (bool success, bytes memory data) = address(proxy).call(abi.encodeWithSignature("get()"));

        assertTrue(success);
        string memory result = abi.decode(data, (string));
        assertEq(result, "beacon logic contract 1");
    }

    //  升级合约后再尝试代理调用
    function test_UpgradeImplementation() public {
        // 部署 logic2
        logic2 = new Logic2();
        // 升级信标指向 logic2
        beacon.upgradeTo(address(logic2));
        // 代理合约调用 get()，应返回 logic2 的内容
        (bool success, bytes memory data) = address(proxy).call(abi.encodeWithSignature("get()"));
        assertTrue(success);
        string memory result = abi.decode(data, (string));
        assertEq(result, "beacon logic contract 2");
    }
}
