// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./AbsOutbox.t.sol";
import "./ERC20Bridge.t.sol";
import "../../src/bridge/ERC20Bridge.sol";
import "../../src/bridge/ERC20Outbox.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

contract ERC20OutboxTest is AbsOutboxTest {
    ERC20Outbox public erc20Outbox;
    ERC20Bridge public erc20Bridge;
    IERC20 public nativeToken;

    uint256 public constant MAX_DATA_SIZE = 117_964;

    function setUp() public {
        // deploy token, bridge and outbox

        // hardcoded proof in tests assume that this contract is deployed at the repsective address
        IERC20 nativeTokenCode = new ERC20PresetFixedSupply(
            "Appchain Token",
            "App",
            1_000_000,
            address(this)
        );
        nativeToken = IERC20(0xFEfC6BAF87cF3684058D62Da40Ff3A795946Ab06);
        vm.etch(address(nativeToken), address(nativeTokenCode).code);
        deal(address(nativeToken), address(this), 1_000_000);

        bridge = IBridge(TestUtil.deployProxy(address(new ERC20Bridge())));
        erc20Bridge = ERC20Bridge(address(bridge));
        outbox = IOutbox(TestUtil.deployProxy(address(new ERC20Outbox())));
        erc20Outbox = ERC20Outbox(address(outbox));

        // init bridge and outbox
        erc20Bridge.initialize(IOwnable(rollup), address(nativeToken));
        erc20Outbox.initialize(IBridge(bridge));

        vm.prank(rollup);
        bridge.setOutbox(address(outbox), true);

        // fund user account
        nativeToken.transfer(user, 1000);
    }

    /* solhint-disable func-name-mixedcase */
    function test_initialize_ERC20() public {
        assertEq(erc20Outbox.l2ToL1WithdrawalAmount(), 0, "Invalid withdrawalAmount");
    }

    function test_initialize_revert_AlreadyInit() public {
        vm.expectRevert(abi.encodeWithSelector(AlreadyInit.selector));
        erc20Outbox.initialize(IBridge(bridge));
    }

    function test_executeTransaction() public {
        // fund bridge with some tokens
        vm.startPrank(user);
        nativeToken.approve(address(bridge), 100);
        nativeToken.transfer(address(bridge), 100);
        vm.stopPrank();

        // create msg receiver on L1
        // hardcoded proof in tests assume that this contract is deployed at the repsective address
        ERC20L2ToL1Target targetCode = new ERC20L2ToL1Target();
        ERC20L2ToL1Target target = ERC20L2ToL1Target(0x87B2d08110B7D50861141D7bBDd49326af3Ecb31);
        vm.etch(address(target), address(targetCode).code);
        target.setOutbox(address(outbox));

        //// execute transaction
        uint256 bridgeTokenBalanceBefore = nativeToken.balanceOf(address(bridge));
        uint256 targetTokenBalanceBefore = nativeToken.balanceOf(address(target));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(0);

        uint256 withdrawalAmount = 15;
        bytes memory data = abi.encodeWithSignature("receiveHook()");

        uint256 index = 1;
        bytes32 itemHash = outbox.calculateItemHash({
            l2Sender: user,
            to: address(target),
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: data
        });
        bytes32 root = outbox.calculateMerkleRoot(proof, index, itemHash);
        // store root
        vm.prank(rollup);
        outbox.updateSendRoot(
            root,
            bytes32(uint256(1))
        );

        outbox.executeTransaction({
            proof: proof,
            index: index,
            l2Sender: user,
            to: address(target),
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: data
        });

        uint256 bridgeTokenBalanceAfter = nativeToken.balanceOf(address(bridge));
        assertEq(
            bridgeTokenBalanceBefore - bridgeTokenBalanceAfter,
            withdrawalAmount,
            "Invalid bridge token balance"
        );

        uint256 targetTokenBalanceAfter = nativeToken.balanceOf(address(target));
        assertEq(
            targetTokenBalanceAfter - targetTokenBalanceBefore,
            withdrawalAmount,
            "Invalid target token balance"
        );

        /// check context was properly set during execution
        assertEq(uint256(target.l2Block()), 300, "Invalid l2Block");
        assertEq(uint256(target.timestamp()), 1234, "Invalid timestamp");
        assertEq(uint256(target.outputId()), index, "Invalid outputId");
        assertEq(target.sender(), user, "Invalid sender");
        assertEq(uint256(target.l1Block()), 20, "Invalid l1Block");
        assertEq(uint256(target.withdrawalAmount()), withdrawalAmount, "Invalid withdrawalAmount");

        vm.expectRevert(abi.encodeWithSignature("AlreadySpent(uint256)", index));
        outbox.executeTransaction({
            proof: proof,
            index: index,
            l2Sender: user,
            to: address(target),
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: data
        });
    }

    function test_executeTransaction_revert_CallTargetNotAllowed() public {
        // // fund bridge with some tokens
        vm.startPrank(user);
        nativeToken.approve(address(bridge), 100);
        nativeToken.transfer(address(bridge), 100);
        vm.stopPrank();

        //// execute transaction
        uint256 bridgeTokenBalanceBefore = nativeToken.balanceOf(address(bridge));
        uint256 userTokenBalanceBefore = nativeToken.balanceOf(address(user));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(0);

        uint256 withdrawalAmount = 15;

        address invalidTarget = address(nativeToken);

        uint256 index = 1;
        bytes32 itemHash = outbox.calculateItemHash({
            l2Sender: user,
            to: invalidTarget,
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: ""
        });
        bytes32 root = outbox.calculateMerkleRoot(proof, index, itemHash);
        // store root
        vm.prank(rollup);
        outbox.updateSendRoot(
            root,
            bytes32(uint256(1))
        );

        vm.expectRevert(abi.encodeWithSelector(CallTargetNotAllowed.selector, invalidTarget));
        outbox.executeTransaction({
            proof: proof,
            index: index,
            l2Sender: user,
            to: invalidTarget,
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: ""
        });

        uint256 bridgeTokenBalanceAfter = nativeToken.balanceOf(address(bridge));
        assertEq(bridgeTokenBalanceBefore, bridgeTokenBalanceAfter, "Invalid bridge token balance");

        uint256 userTokenBalanceAfter = nativeToken.balanceOf(address(user));
        assertEq(userTokenBalanceAfter, userTokenBalanceBefore, "Invalid user token balance");
    }

    function test_executeTransaction_DecimalsLessThan18() public {
        // create token/bridge/inbox
        uint8 decimals = 6;
        ERC20 _nativeToken = new ERC20_6Decimals();

        IERC20Bridge _bridge = IERC20Bridge(TestUtil.deployProxy(address(new ERC20Bridge())));
        IERC20Inbox _inbox = IERC20Inbox(TestUtil.deployProxy(address(new ERC20Inbox(MAX_DATA_SIZE))));
        ERC20Outbox _outbox = ERC20Outbox(TestUtil.deployProxy(address(new ERC20Outbox())));

        // init bridge and inbox
        address _rollup = makeAddr("_rollup");
        _bridge.initialize(IOwnable(_rollup), address(_nativeToken));
        _inbox.initialize(_bridge, ISequencerInbox(makeAddr("_seqInbox")));
        _outbox.initialize(IBridge(address(_bridge)));
        vm.prank(_rollup);
        _bridge.setOutbox(address(_outbox), true);

        // fund bridge with some tokens
        ERC20_6Decimals(address(_nativeToken)).mint(address(_bridge), 1_000_000 * 10 ** decimals);

        // create msg receiver on L1
        ERC20L2ToL1Target target = new ERC20L2ToL1Target();
        target.setOutbox(address(_outbox));

        //// execute transaction
        uint256 bridgeTokenBalanceBefore = _nativeToken.balanceOf(address(_bridge));
        uint256 targetTokenBalanceBefore = _nativeToken.balanceOf(address(target));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(0);

        uint256 withdrawalAmount = 188_394_098_124_747_940;
        uint256 expetedAmountToUnlock = withdrawalAmount / (10 ** (18 - decimals));

        bytes memory data = abi.encodeWithSignature("receiveHook()");

        uint256 index = 1;
        {
            bytes32 itemHash = _outbox.calculateItemHash({
                l2Sender: user,
                to: address(target),
                l2Block: 300,
                l1Block: 20,
                l2Timestamp: 1234,
                value: withdrawalAmount,
                data: data
            });
            bytes32 root = _outbox.calculateMerkleRoot(proof, index, itemHash);
            // store root
            vm.prank(_rollup);
            _outbox.updateSendRoot(
                root,
                bytes32(uint256(1))
            );
        }

        _outbox.executeTransaction({
            proof: proof,
            index: index,
            l2Sender: user,
            to: address(target),
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: data
        });

        uint256 bridgeTokenBalanceAfter = _nativeToken.balanceOf(address(_bridge));
        assertEq(
            bridgeTokenBalanceBefore - bridgeTokenBalanceAfter,
            expetedAmountToUnlock,
            "Invalid bridge token balance"
        );

        uint256 targetTokenBalanceAfter = _nativeToken.balanceOf(address(target));
        assertEq(
            targetTokenBalanceAfter - targetTokenBalanceBefore,
            expetedAmountToUnlock,
            "Invalid target token balance"
        );

        /// check context was properly set during execution
        assertEq(uint256(target.l2Block()), 300, "Invalid l2Block");
        assertEq(uint256(target.timestamp()), 1234, "Invalid timestamp");
        assertEq(uint256(target.outputId()), index, "Invalid outputId");
        assertEq(target.sender(), user, "Invalid sender");
        assertEq(uint256(target.l1Block()), 20, "Invalid l1Block");
        assertEq(
            uint256(target.withdrawalAmount()),
            expetedAmountToUnlock,
            "Invalid expetedAmountToUnlock"
        );

        vm.expectRevert(abi.encodeWithSignature("AlreadySpent(uint256)", index));
        _outbox.executeTransaction({
            proof: proof,
            index: index,
            l2Sender: user,
            to: address(target),
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: data
        });
    }

    function test_executeTransaction_DecimalsMoreThan18() public {
        // create token/bridge/inbox
        uint8 decimals = 20;
        ERC20 _nativeToken = new ERC20_20Decimals();

        IERC20Bridge _bridge = IERC20Bridge(TestUtil.deployProxy(address(new ERC20Bridge())));
        IERC20Inbox _inbox = IERC20Inbox(TestUtil.deployProxy(address(new ERC20Inbox(MAX_DATA_SIZE))));
        ERC20Outbox _outbox = ERC20Outbox(TestUtil.deployProxy(address(new ERC20Outbox())));

        // init bridge and inbox
        address _rollup = makeAddr("_rollup");
        _bridge.initialize(IOwnable(_rollup), address(_nativeToken));
        _inbox.initialize(_bridge, ISequencerInbox(makeAddr("_seqInbox")));
        _outbox.initialize(IBridge(address(_bridge)));
        vm.prank(_rollup);
        _bridge.setOutbox(address(_outbox), true);

        // fund bridge with some tokens
        ERC20_20Decimals(address(_nativeToken)).mint(address(_bridge), 1_000_000 * 10 ** decimals);

        // create msg receiver on L1
        ERC20L2ToL1Target target = new ERC20L2ToL1Target();
        target.setOutbox(address(_outbox));

        //// execute transaction
        uint256 bridgeTokenBalanceBefore = _nativeToken.balanceOf(address(_bridge));
        uint256 targetTokenBalanceBefore = _nativeToken.balanceOf(address(target));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(0);

        uint256 withdrawalAmount = 188_394_098_124_747_940;
        uint256 expetedAmountToUnlock = withdrawalAmount * (10 ** (decimals - 18));

        bytes memory data = abi.encodeWithSignature("receiveHook()");

        uint256 index = 1;
        {
            bytes32 itemHash = _outbox.calculateItemHash({
                l2Sender: user,
                to: address(target),
                l2Block: 300,
                l1Block: 20,
                l2Timestamp: 1234,
                value: withdrawalAmount,
                data: data
            });
            bytes32 root = _outbox.calculateMerkleRoot(proof, index, itemHash);
            // store root
            vm.prank(_rollup);
            _outbox.updateSendRoot(
                root,
                bytes32(uint256(1))
            );
        }

        _outbox.executeTransaction({
            proof: proof,
            index: index,
            l2Sender: user,
            to: address(target),
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: data
        });

        uint256 bridgeTokenBalanceAfter = _nativeToken.balanceOf(address(_bridge));
        assertEq(
            bridgeTokenBalanceBefore - bridgeTokenBalanceAfter,
            expetedAmountToUnlock,
            "Invalid bridge token balance"
        );

        uint256 targetTokenBalanceAfter = _nativeToken.balanceOf(address(target));
        assertEq(
            targetTokenBalanceAfter - targetTokenBalanceBefore,
            expetedAmountToUnlock,
            "Invalid target token balance"
        );

        /// check context was properly set during execution
        assertEq(uint256(target.l2Block()), 300, "Invalid l2Block");
        assertEq(uint256(target.timestamp()), 1234, "Invalid timestamp");
        assertEq(uint256(target.outputId()), index, "Invalid outputId");
        assertEq(target.sender(), user, "Invalid sender");
        assertEq(uint256(target.l1Block()), 20, "Invalid l1Block");
        assertEq(
            uint256(target.withdrawalAmount()),
            expetedAmountToUnlock,
            "Invalid expetedAmountToUnlock"
        );

        vm.expectRevert(abi.encodeWithSignature("AlreadySpent(uint256)", index));
        _outbox.executeTransaction({
            proof: proof,
            index: index,
            l2Sender: user,
            to: address(target),
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: withdrawalAmount,
            data: data
        });
    }

    function test_executeTransaction_revert_AmountTooLarge() public {
        // create token/bridge/inbox
        ERC20 _nativeToken = new ERC20_36Decimals();

        IERC20Bridge _bridge = IERC20Bridge(TestUtil.deployProxy(address(new ERC20Bridge())));
        IERC20Inbox _inbox = IERC20Inbox(TestUtil.deployProxy(address(new ERC20Inbox(MAX_DATA_SIZE))));
        ERC20Outbox _outbox = ERC20Outbox(TestUtil.deployProxy(address(new ERC20Outbox())));

        // init bridge and inbox
        address _rollup = makeAddr("_rollup");
        _bridge.initialize(IOwnable(_rollup), address(_nativeToken));
        _inbox.initialize(_bridge, ISequencerInbox(makeAddr("_seqInbox")));
        _outbox.initialize(IBridge(address(_bridge)));
        vm.prank(_rollup);
        _bridge.setOutbox(address(_outbox), true);

        // fund bridge with some tokens
        ERC20_36Decimals(address(_nativeToken)).mint(address(_bridge), type(uint256).max / 100);

        // create msg receiver on L1
        ERC20L2ToL1Target target = new ERC20L2ToL1Target();
        target.setOutbox(address(_outbox));

        //// execute transaction
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(0);

        uint256 tooLargeWithdrawalAmount = type(uint256).max / 10 ** 18 + 1;

        bytes memory data = abi.encodeWithSignature("receiveHook()");

        uint256 index = 1;
        {
            bytes32 itemHash = _outbox.calculateItemHash({
                l2Sender: user,
                to: address(target),
                l2Block: 300,
                l1Block: 20,
                l2Timestamp: 1234,
                value: tooLargeWithdrawalAmount,
                data: data
            });
            bytes32 root = _outbox.calculateMerkleRoot(proof, index, itemHash);
            // store root
            vm.prank(_rollup);
            _outbox.updateSendRoot(
                root,
                bytes32(uint256(1))
            );
        }

        vm.expectRevert(stdError.arithmeticError); // overflow
        _outbox.executeTransaction({
            proof: proof,
            index: index,
            l2Sender: user,
            to: address(target),
            l2Block: 300,
            l1Block: 20,
            l2Timestamp: 1234,
            value: tooLargeWithdrawalAmount,
            data: data
        });
    }
}

/**
 * Contract for testing L2 to L1 msgs
 */
contract ERC20L2ToL1Target {
    address public outbox;

    uint128 public l2Block;
    uint128 public timestamp;
    bytes32 public outputId;
    address public sender;
    uint96 public l1Block;
    uint256 public withdrawalAmount;

    function receiveHook() external payable {
        l2Block = uint128(IOutbox(outbox).l2ToL1Block());
        timestamp = uint128(IOutbox(outbox).l2ToL1Timestamp());
        outputId = IOutbox(outbox).l2ToL1OutputId();
        sender = IOutbox(outbox).l2ToL1Sender();
        l1Block = uint96(IOutbox(outbox).l2ToL1EthBlock());
        withdrawalAmount = ERC20Outbox(outbox).l2ToL1WithdrawalAmount();
    }

    function setOutbox(address _outbox) external {
        outbox = _outbox;
    }
}
