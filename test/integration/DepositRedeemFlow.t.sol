// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";
import {Tranche} from "src/vaults/ShareToken.sol";
import {SpokeInvestmentManager} from "src/managers/spoke/SpokeInvestmentManager.sol";
import {SpokeHandler} from "src/core/spoke/SpokeHandler.sol";
import {RiyzoSpoke} from "src/core/spoke/RiyzoSpoke.sol";
import {BalanceSheet} from "src/core/spoke/BalanceSheet.sol";
import {PoolEscrow} from "src/core/spoke/PoolEscrow.sol";
import {VaultRegistry} from "src/core/spoke/VaultRegistry.sol";
import {RestrictionManager} from "src/hooks/RestrictionManager.sol";
import {IRiyzoSpoke} from "src/interfaces/spoke/IRiyzoSpoke.sol";
import {MessagesLib} from "src/core/libraries/MessagesLib.sol";
import {MockGateway} from "test/mocks/MockGateway.sol";
import {MockEscrow} from "test/mocks/MockEscrow.sol";
import {MockVaultFactory} from "test/mocks/MockVaultFactory.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @dev Minimal root mock providing endorsed() and paused()
contract MockRoot {
    mapping(address => bool) public endorsed;
    bool public paused;
    uint256 public delay;
    mapping(address => uint256) public endorsements;

    function endorse(address user) external {
        endorsed[user] = true;
        endorsements[user] = 1;
    }

    function veto(address user) external {
        endorsed[user] = false;
        endorsements[user] = 0;
    }

    function schedule(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Tranche factory that returns a pre-deployed token
contract FixedTrancheFactory {
    address public fixedToken;

    constructor(address token) {
        fixedToken = token;
    }

    function newTranche(uint64, bytes16, string memory, string memory, uint8, address[] calldata)
        external
        view
        returns (address)
    {
        return fixedToken;
    }
}

/// @title DepositRedeemFlowTest - Integration tests for end-to-end spoke deposit/redeem
contract DepositRedeemFlowTest is Test {
    // --- Contracts ---
    ERC7540Vault public vault;
    Tranche public shareToken;
    SpokeInvestmentManager public investmentManager;
    SpokeHandler public handler;
    RiyzoSpoke public spoke;
    BalanceSheet public balanceSheet;
    PoolEscrow public poolEscrow;
    VaultRegistry public vaultRegistry;
    RestrictionManager public restrictionManager;
    MockGateway public gateway;
    MockEscrow public escrow;
    MockRoot public root;
    MockERC20 public usdc;
    MockVaultFactory public vaultFactory;

    // --- Addresses ---
    address public admin = address(this);
    address public user1 = address(0xA1);
    address public user2 = address(0xA2);
    address public user3 = address(0xA3);

    // --- Constants ---
    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));
    uint128 public constant ASSET_ID = 1;
    uint128 public constant PRICE = 1e18;

    function setUp() public {
        // Deploy infrastructure mocks
        gateway = new MockGateway();
        escrow = new MockEscrow();
        root = new MockRoot();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vaultFactory = new MockVaultFactory();

        // Deploy real share token
        shareToken = new Tranche(18);
        shareToken.file("name", "Senior Tranche");
        shareToken.file("symbol", "SR");

        // Deploy RestrictionManager as hook
        restrictionManager = new RestrictionManager(address(root), admin);
        shareToken.file("hook", address(restrictionManager));

        // Deploy spoke layer
        spoke = new RiyzoSpoke(admin);
        balanceSheet = new BalanceSheet(admin);
        poolEscrow = new PoolEscrow(admin, address(escrow));
        vaultRegistry = new VaultRegistry(admin, address(root), address(escrow));
        handler = new SpokeHandler(admin);
        investmentManager = new SpokeInvestmentManager(address(escrow), admin);

        // Deploy real ERC7540Vault
        vault = new ERC7540Vault(
            POOL_ID,
            SC_ID,
            address(usdc),
            address(shareToken),
            address(root),
            address(escrow),
            address(investmentManager)
        );

        // --- Wire spoke configuration ---
        spoke.file("gateway", address(gateway));
        spoke.file("vaultRegistry", address(vaultRegistry));
        spoke.file("balanceSheet", address(balanceSheet));
        spoke.file("poolEscrow", address(poolEscrow));
        spoke.file("spokeHandler", address(handler));

        vaultRegistry.file("vaultFactory", address(vaultFactory));
        vaultRegistry.file("trancheFactory", address(new FixedTrancheFactory(address(shareToken))));

        handler.file("gateway", address(gateway));
        handler.file("spoke", address(spoke));
        handler.file("balanceSheet", address(balanceSheet));
        handler.file("poolEscrow", address(poolEscrow));
        handler.file("spokeInvestmentManager", address(investmentManager));
        handler.file("restrictionManager", address(restrictionManager));

        investmentManager.file("spoke", address(spoke));

        // --- Auth wiring ---
        investmentManager.rely(address(vault));
        vault.rely(address(investmentManager));
        investmentManager.rely(address(handler));
        restrictionManager.rely(address(handler));
        spoke.rely(address(handler));
        spoke.rely(address(investmentManager));
        balanceSheet.rely(address(handler));
        poolEscrow.rely(address(handler));
        shareToken.rely(address(investmentManager));
        vaultRegistry.rely(address(spoke));
        balanceSheet.rely(address(spoke));
        poolEscrow.rely(address(spoke));

        // Escrow approvals
        escrow.approveMax(address(usdc), address(investmentManager));
        escrow.approveMax(address(shareToken), address(investmentManager));
        root.endorse(address(escrow));

        // Register pool and share class
        spoke.registerPool(POOL_ID, address(usdc));
        spoke.registerShareClass(POOL_ID, SC_ID, "Senior", "SR");
        spoke.linkVault(POOL_ID, SC_ID, address(usdc), address(vault));
        spoke.updatePrice(POOL_ID, SC_ID, PRICE, uint64(block.timestamp));

        balanceSheet.setShareToken(POOL_ID, SC_ID, address(shareToken));
        shareToken.updateVault(address(usdc), address(vault));

        // Fund escrow
        usdc.mint(address(escrow), 10_000_000e6);

        // Add users to memberlist
        restrictionManager.updateMember(address(shareToken), user1, uint64(block.timestamp + 365 days));
        restrictionManager.updateMember(address(shareToken), user2, uint64(block.timestamp + 365 days));
        restrictionManager.updateMember(address(shareToken), user3, uint64(block.timestamp + 365 days));

        // Fund users
        usdc.mint(user1, 10_000e6);
        usdc.mint(user2, 10_000e6);
        usdc.mint(user3, 10_000e6);
    }

    // ============================================================
    // TEST 1: Full deposit flow
    // ============================================================

    function test_fullDepositFlow() public {
        uint128 depositAmount = 1000e6;

        // User approves and requests deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, user1, user1);
        vm.stopPrank();

        assertEq(vault.pendingDepositRequest(0, user1), depositAmount);
        assertEq(usdc.balanceOf(address(escrow)), 10_000_000e6 + depositAmount);

        // Hub fulfills deposit
        _sendFulfilledDeposit(POOL_ID, SC_ID, user1, ASSET_ID, depositAmount, 1000e18);

        assertEq(vault.maxMint(user1), 1000e18);
        assertEq(vault.maxDeposit(user1), depositAmount);
        assertEq(shareToken.balanceOf(address(escrow)), 1000e18);

        // User claims shares
        vm.prank(user1);
        vault.mint(1000e18, user1);

        assertEq(shareToken.balanceOf(user1), 1000e18);
        assertEq(shareToken.balanceOf(address(escrow)), 0);
        assertEq(vault.maxMint(user1), 0);
    }

    // ============================================================
    // TEST 2: Full redeem flow
    // ============================================================

    function test_fullRedeemFlow() public {
        _depositAndClaim(user1, 1000e6, 1000e18);

        vm.startPrank(user1);
        shareToken.approve(address(vault), 1000e18);
        vault.requestRedeem(1000e18, user1, user1);
        vm.stopPrank();

        assertEq(vault.pendingRedeemRequest(0, user1), 1000e18);
        assertEq(shareToken.balanceOf(address(escrow)), 1000e18);

        _sendFulfilledRedeem(POOL_ID, SC_ID, user1, ASSET_ID, 1000e6, 1000e18);

        assertEq(vault.maxWithdraw(user1), 1000e6);
        assertEq(shareToken.balanceOf(address(escrow)), 0);

        vm.prank(user1);
        vault.withdraw(1000e6, user1, user1);

        assertEq(usdc.balanceOf(user1), 10_000e6);
        assertEq(vault.maxWithdraw(user1), 0);
    }

    // ============================================================
    // TEST 3: Cancel deposit flow
    // ============================================================

    function test_cancelDepositFlow() public {
        uint128 depositAmount = 500e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, user1, user1);
        vault.cancelDepositRequest(0, user1);
        vm.stopPrank();

        assertTrue(vault.pendingCancelDepositRequest(0, user1));

        _sendFulfilledCancelDeposit(POOL_ID, SC_ID, user1, ASSET_ID, depositAmount, depositAmount);

        assertEq(vault.claimableCancelDepositRequest(0, user1), depositAmount);
        assertFalse(vault.pendingCancelDepositRequest(0, user1));

        vm.prank(user1);
        vault.claimCancelDepositRequest(0, user1, user1);

        assertEq(usdc.balanceOf(user1), 10_000e6);
    }

    // ============================================================
    // TEST 4: Cancel redeem flow
    // ============================================================

    function test_cancelRedeemFlow() public {
        _depositAndClaim(user1, 1000e6, 1000e18);

        vm.startPrank(user1);
        shareToken.approve(address(vault), 1000e18);
        vault.requestRedeem(1000e18, user1, user1);
        vault.cancelRedeemRequest(0, user1);
        vm.stopPrank();

        assertTrue(vault.pendingCancelRedeemRequest(0, user1));

        _sendFulfilledCancelRedeem(POOL_ID, SC_ID, user1, ASSET_ID, 1000e18);

        assertEq(vault.claimableCancelRedeemRequest(0, user1), 1000e18);

        vm.prank(user1);
        vault.claimCancelRedeemRequest(0, user1, user1);

        assertEq(shareToken.balanceOf(user1), 1000e18);
    }

    // ============================================================
    // TEST 5: Price conversion accuracy
    // ============================================================

    function test_priceConversion() public {
        spoke.updatePrice(POOL_ID, SC_ID, 1.05e18, uint64(block.timestamp));

        uint256 shares = vault.convertToShares(1000e6);
        assertApproxEqAbs(shares, 952380952380952380952, 1e15);

        uint256 assets = vault.convertToAssets(1000e18);
        assertEq(assets, 1050e6);
    }

    // ============================================================
    // TEST 6: UpdateRestriction message handling
    // ============================================================

    function test_updateRestrictionMessage() public {
        address newUser = address(0xB1);
        uint64 validUntil = uint64(block.timestamp + 365 days);

        // Restriction update payload: [type(1), address(20), padding(12), validUntil(8)]
        bytes memory message = abi.encodePacked(
            uint8(MessagesLib.Call.UpdateRestriction),
            POOL_ID,
            SC_ID,
            uint8(1), // RestrictionUpdate.UpdateMember
            bytes20(newUser),
            bytes12(0), // padding to 32 bytes for address
            validUntil
        );

        handler.handle(message);

        (bool isValid, uint64 storedValidUntil) = restrictionManager.isMember(address(shareToken), newUser);
        assertTrue(isValid);
        assertEq(storedValidUntil, validUntil);
    }

    // ============================================================
    // TEST 7: Multi-user epoch
    // ============================================================

    function test_multiUserEpoch() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(vault), 2000e6);
        vault.requestDeposit(2000e6, user2, user2);
        vm.stopPrank();

        _sendFulfilledDeposit(POOL_ID, SC_ID, user1, ASSET_ID, 1000e6, 1000e18);
        _sendFulfilledDeposit(POOL_ID, SC_ID, user2, ASSET_ID, 2000e6, 2000e18);

        vm.prank(user1);
        vault.mint(1000e18, user1);
        vm.prank(user2);
        vault.mint(2000e18, user2);

        assertEq(shareToken.balanceOf(user1), 1000e18);
        assertEq(shareToken.balanceOf(user2), 2000e18);
    }

    // ============================================================
    // TEST 8: Partial fulfillment
    // ============================================================

    function test_partialFulfillment() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        _sendFulfilledDeposit(POOL_ID, SC_ID, user1, ASSET_ID, 400e6, 400e18);

        assertEq(vault.maxMint(user1), 400e18);
        assertEq(vault.pendingDepositRequest(0, user1), 600e6);

        vm.prank(user1);
        vault.mint(400e18, user1);
        assertEq(shareToken.balanceOf(user1), 400e18);

        _sendFulfilledDeposit(POOL_ID, SC_ID, user1, ASSET_ID, 600e6, 600e18);

        assertEq(vault.maxMint(user1), 600e18);
        assertEq(vault.pendingDepositRequest(0, user1), 0);

        vm.prank(user1);
        vault.mint(600e18, user1);
        assertEq(shareToken.balanceOf(user1), 1000e18);
    }

    // ============================================================
    // TEST 9: Price update via handler
    // ============================================================

    function test_priceUpdateViaHandler() public {
        uint128 newPrice = 1.1e18;
        uint64 ts = uint64(block.timestamp + 100);

        bytes memory message =
            abi.encodePacked(uint8(MessagesLib.Call.UpdateTranchePrice), POOL_ID, SC_ID, newPrice, ts);
        handler.handle(message);

        assertEq(vault.priceLastUpdated(), ts);
        assertEq(vault.convertToAssets(1000e18), 1100e6);
    }

    // ============================================================
    // TEST 10: Restriction enforcement
    // ============================================================

    function test_restrictedUserCannotDeposit() public {
        address restrictedUser = address(0xC1);
        usdc.mint(restrictedUser, 1000e6);

        vm.startPrank(restrictedUser);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert("SpokeInvestmentManager/transfer-not-allowed");
        vault.requestDeposit(1000e6, restrictedUser, restrictedUser);
        vm.stopPrank();
    }

    // ============================================================
    // TEST 11: Batch member update
    // ============================================================

    function test_batchUpdateMember() public {
        address[] memory users = new address[](3);
        users[0] = address(0xD1);
        users[1] = address(0xD2);
        users[2] = address(0xD3);

        uint64[] memory validUntils = new uint64[](3);
        validUntils[0] = uint64(block.timestamp + 365 days);
        validUntils[1] = uint64(block.timestamp + 365 days);
        validUntils[2] = uint64(block.timestamp + 365 days);

        restrictionManager.batchUpdateMember(address(shareToken), users, validUntils);

        for (uint256 i = 0; i < users.length; i++) {
            (bool isValid,) = restrictionManager.isMember(address(shareToken), users[i]);
            assertTrue(isValid);
        }
    }

    // ============================================================
    // TEST 12: Deposit + redeem round trip
    // ============================================================

    function test_depositRedeemRoundTrip() public {
        uint256 initialBalance = usdc.balanceOf(user1);

        _depositAndClaim(user1, 1000e6, 1000e18);
        assertEq(usdc.balanceOf(user1), initialBalance - 1000e6);
        assertEq(shareToken.balanceOf(user1), 1000e18);

        vm.startPrank(user1);
        shareToken.approve(address(vault), 1000e18);
        vault.requestRedeem(1000e18, user1, user1);
        vm.stopPrank();

        _sendFulfilledRedeem(POOL_ID, SC_ID, user1, ASSET_ID, 1000e6, 1000e18);

        vm.prank(user1);
        vault.withdraw(1000e6, user1, user1);

        assertEq(usdc.balanceOf(user1), initialBalance);
        assertEq(shareToken.balanceOf(user1), 0);
    }

    // ============================================================
    // MESSAGE ENCODING HELPERS
    // ============================================================

    function _sendFulfilledDeposit(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) internal {
        bytes memory message = abi.encodePacked(
            uint8(MessagesLib.Call.FulfilledDepositRequest), poolId, scId, _toBytes32(user), assetId, assets, shares
        );
        handler.handle(message);
    }

    function _sendFulfilledRedeem(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) internal {
        bytes memory message = abi.encodePacked(
            uint8(MessagesLib.Call.FulfilledRedeemRequest), poolId, scId, _toBytes32(user), assetId, assets, shares
        );
        handler.handle(message);
    }

    function _sendFulfilledCancelDeposit(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) internal {
        bytes memory message = abi.encodePacked(
            uint8(MessagesLib.Call.FulfilledCancelDepositRequest),
            poolId,
            scId,
            _toBytes32(user),
            assetId,
            assets,
            fulfillment
        );
        handler.handle(message);
    }

    function _sendFulfilledCancelRedeem(uint64 poolId, bytes16 scId, address user, uint128 assetId, uint128 shares)
        internal
    {
        bytes memory message = abi.encodePacked(
            uint8(MessagesLib.Call.FulfilledCancelRedeemRequest), poolId, scId, _toBytes32(user), assetId, shares
        );
        handler.handle(message);
    }

    /// @dev Right-aligned bytes32 encoding of address (matches SpokeHandler._bytes32ToAddress)
    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function _depositAndClaim(address user, uint128 assetAmount, uint128 shareAmount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), assetAmount);
        vault.requestDeposit(assetAmount, user, user);
        vm.stopPrank();

        _sendFulfilledDeposit(POOL_ID, SC_ID, user, ASSET_ID, assetAmount, shareAmount);

        vm.prank(user);
        vault.mint(shareAmount, user);
    }
}
