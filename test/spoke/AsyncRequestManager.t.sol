// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AsyncRequestManager} from "src/managers/spoke/AsyncRequestManager.sol";
import {IAsyncRequestManager} from "src/interfaces/spoke/IAsyncRequestManager.sol";

/// @title AsyncRequestManagerTest - Unit tests for AsyncRequestManager.sol
contract AsyncRequestManagerTest is Test {
    AsyncRequestManager public requestManager;

    address public admin = address(this);
    address public vault = address(0xABCD);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public unauthorized = address(0x999);

    uint64 public constant EPOCH_ID = 1;

    function setUp() public {
        requestManager = new AsyncRequestManager(admin);
    }

    // ============================================================
    // DEPOSIT REQUEST TESTS
    // ============================================================

    function test_createDepositRequest() public {
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);

        IAsyncRequestManager.DepositRequest memory req = requestManager.getDepositRequest(vault, user1);
        assertEq(req.assets, 1000e6);
        assertEq(req.shares, 0);
        assertEq(req.epochId, EPOCH_ID);
        assertEq(uint8(req.state), uint8(IAsyncRequestManager.RequestState.Pending));
    }

    function test_createDepositRequest_revert_zeroAmount() public {
        vm.expectRevert(IAsyncRequestManager.ZeroAmount.selector);
        requestManager.createDepositRequest(vault, user1, 0, EPOCH_ID);
    }

    function test_createDepositRequest_revert_alreadyPending() public {
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);

        vm.expectRevert(abi.encodeWithSelector(IAsyncRequestManager.RequestAlreadyPending.selector, vault, user1));
        requestManager.createDepositRequest(vault, user1, 500e6, EPOCH_ID);
    }

    function test_createDepositRequest_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
    }

    function test_fulfillDeposit() public {
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
        requestManager.fulfillDeposit(vault, user1, 100e18);

        IAsyncRequestManager.DepositRequest memory req = requestManager.getDepositRequest(vault, user1);
        assertEq(req.shares, 100e18);
        assertEq(uint8(req.state), uint8(IAsyncRequestManager.RequestState.Claimable));
    }

    function test_fulfillDeposit_revert_notPending() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAsyncRequestManager.InvalidRequestState.selector,
                vault,
                user1,
                IAsyncRequestManager.RequestState.None,
                IAsyncRequestManager.RequestState.Pending
            )
        );
        requestManager.fulfillDeposit(vault, user1, 100e18);
    }

    function test_claimDeposit() public {
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
        requestManager.fulfillDeposit(vault, user1, 100e18);

        uint128 shares = requestManager.claimDeposit(vault, user1);

        assertEq(shares, 100e18);
        IAsyncRequestManager.DepositRequest memory req = requestManager.getDepositRequest(vault, user1);
        assertEq(uint8(req.state), uint8(IAsyncRequestManager.RequestState.Claimed));
    }

    function test_claimDeposit_revert_notClaimable() public {
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAsyncRequestManager.InvalidRequestState.selector,
                vault,
                user1,
                IAsyncRequestManager.RequestState.Pending,
                IAsyncRequestManager.RequestState.Claimable
            )
        );
        requestManager.claimDeposit(vault, user1);
    }

    function test_cancelDepositRequest() public {
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
        requestManager.cancelDepositRequest(vault, user1);

        IAsyncRequestManager.DepositRequest memory req = requestManager.getDepositRequest(vault, user1);
        assertEq(uint8(req.state), uint8(IAsyncRequestManager.RequestState.Cancelled));
    }

    function test_cancelDepositRequest_revert_notPending() public {
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
        requestManager.fulfillDeposit(vault, user1, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAsyncRequestManager.InvalidRequestState.selector,
                vault,
                user1,
                IAsyncRequestManager.RequestState.Claimable,
                IAsyncRequestManager.RequestState.Pending
            )
        );
        requestManager.cancelDepositRequest(vault, user1);
    }

    // ============================================================
    // REDEEM REQUEST TESTS
    // ============================================================

    function test_createRedeemRequest() public {
        requestManager.createRedeemRequest(vault, user1, 100e18, EPOCH_ID);

        IAsyncRequestManager.RedeemRequest memory req = requestManager.getRedeemRequest(vault, user1);
        assertEq(req.shares, 100e18);
        assertEq(req.assets, 0);
        assertEq(req.epochId, EPOCH_ID);
        assertEq(uint8(req.state), uint8(IAsyncRequestManager.RequestState.Pending));
    }

    function test_createRedeemRequest_revert_zeroAmount() public {
        vm.expectRevert(IAsyncRequestManager.ZeroAmount.selector);
        requestManager.createRedeemRequest(vault, user1, 0, EPOCH_ID);
    }

    function test_createRedeemRequest_revert_alreadyPending() public {
        requestManager.createRedeemRequest(vault, user1, 100e18, EPOCH_ID);

        vm.expectRevert(abi.encodeWithSelector(IAsyncRequestManager.RequestAlreadyPending.selector, vault, user1));
        requestManager.createRedeemRequest(vault, user1, 50e18, EPOCH_ID);
    }

    function test_fulfillRedeem() public {
        requestManager.createRedeemRequest(vault, user1, 100e18, EPOCH_ID);
        requestManager.fulfillRedeem(vault, user1, 1000e6);

        IAsyncRequestManager.RedeemRequest memory req = requestManager.getRedeemRequest(vault, user1);
        assertEq(req.assets, 1000e6);
        assertEq(uint8(req.state), uint8(IAsyncRequestManager.RequestState.Claimable));
    }

    function test_claimRedeem() public {
        requestManager.createRedeemRequest(vault, user1, 100e18, EPOCH_ID);
        requestManager.fulfillRedeem(vault, user1, 1000e6);

        uint128 assets = requestManager.claimRedeem(vault, user1);

        assertEq(assets, 1000e6);
        IAsyncRequestManager.RedeemRequest memory req = requestManager.getRedeemRequest(vault, user1);
        assertEq(uint8(req.state), uint8(IAsyncRequestManager.RequestState.Claimed));
    }

    function test_cancelRedeemRequest() public {
        requestManager.createRedeemRequest(vault, user1, 100e18, EPOCH_ID);
        requestManager.cancelRedeemRequest(vault, user1);

        IAsyncRequestManager.RedeemRequest memory req = requestManager.getRedeemRequest(vault, user1);
        assertEq(uint8(req.state), uint8(IAsyncRequestManager.RequestState.Cancelled));
    }

    // ============================================================
    // VIEW FUNCTION TESTS (ERC-7540 compatibility)
    // ============================================================

    function test_pendingDeposit() public {
        assertEq(requestManager.pendingDeposit(vault, user1), 0);

        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
        assertEq(requestManager.pendingDeposit(vault, user1), 1000e6);

        requestManager.fulfillDeposit(vault, user1, 100e18);
        assertEq(requestManager.pendingDeposit(vault, user1), 0); // No longer pending
    }

    function test_claimableDeposit() public {
        assertEq(requestManager.claimableDeposit(vault, user1), 0);

        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
        assertEq(requestManager.claimableDeposit(vault, user1), 0); // Not yet claimable

        requestManager.fulfillDeposit(vault, user1, 100e18);
        assertEq(requestManager.claimableDeposit(vault, user1), 100e18);

        requestManager.claimDeposit(vault, user1);
        assertEq(requestManager.claimableDeposit(vault, user1), 0); // Already claimed
    }

    function test_pendingRedeem() public {
        assertEq(requestManager.pendingRedeem(vault, user1), 0);

        requestManager.createRedeemRequest(vault, user1, 100e18, EPOCH_ID);
        assertEq(requestManager.pendingRedeem(vault, user1), 100e18);

        requestManager.fulfillRedeem(vault, user1, 1000e6);
        assertEq(requestManager.pendingRedeem(vault, user1), 0);
    }

    function test_claimableRedeem() public {
        assertEq(requestManager.claimableRedeem(vault, user1), 0);

        requestManager.createRedeemRequest(vault, user1, 100e18, EPOCH_ID);
        assertEq(requestManager.claimableRedeem(vault, user1), 0);

        requestManager.fulfillRedeem(vault, user1, 1000e6);
        assertEq(requestManager.claimableRedeem(vault, user1), 1000e6);

        requestManager.claimRedeem(vault, user1);
        assertEq(requestManager.claimableRedeem(vault, user1), 0);
    }

    function test_hasPendingRequest() public {
        assertFalse(requestManager.hasPendingRequest(vault, user1));

        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
        assertTrue(requestManager.hasPendingRequest(vault, user1));

        requestManager.fulfillDeposit(vault, user1, 100e18);
        assertFalse(requestManager.hasPendingRequest(vault, user1));
    }

    function test_hasPendingRequest_redeem() public {
        requestManager.createRedeemRequest(vault, user1, 100e18, EPOCH_ID);
        assertTrue(requestManager.hasPendingRequest(vault, user1));
    }

    // ============================================================
    // MULTIPLE USERS TESTS
    // ============================================================

    function test_multipleUsers() public {
        requestManager.createDepositRequest(vault, user1, 1000e6, EPOCH_ID);
        requestManager.createDepositRequest(vault, user2, 2000e6, EPOCH_ID);

        assertEq(requestManager.pendingDeposit(vault, user1), 1000e6);
        assertEq(requestManager.pendingDeposit(vault, user2), 2000e6);

        requestManager.fulfillDeposit(vault, user1, 100e18);
        requestManager.fulfillDeposit(vault, user2, 200e18);

        assertEq(requestManager.claimableDeposit(vault, user1), 100e18);
        assertEq(requestManager.claimableDeposit(vault, user2), 200e18);
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_depositLifecycle(uint128 assets, uint128 shares) public {
        vm.assume(assets > 0);
        vm.assume(shares > 0);

        requestManager.createDepositRequest(vault, user1, assets, EPOCH_ID);
        assertEq(requestManager.pendingDeposit(vault, user1), assets);

        requestManager.fulfillDeposit(vault, user1, shares);
        assertEq(requestManager.claimableDeposit(vault, user1), shares);

        uint128 claimed = requestManager.claimDeposit(vault, user1);
        assertEq(claimed, shares);
    }

    function testFuzz_redeemLifecycle(uint128 shares, uint128 assets) public {
        vm.assume(shares > 0);
        vm.assume(assets > 0);

        requestManager.createRedeemRequest(vault, user1, shares, EPOCH_ID);
        assertEq(requestManager.pendingRedeem(vault, user1), shares);

        requestManager.fulfillRedeem(vault, user1, assets);
        assertEq(requestManager.claimableRedeem(vault, user1), assets);

        uint128 claimed = requestManager.claimRedeem(vault, user1);
        assertEq(claimed, assets);
    }
}
