// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpokeInvestmentManager} from "src/managers/spoke/SpokeInvestmentManager.sol";
import {IInvestmentManager, InvestmentState} from "src/interfaces/IInvestmentManager.sol";
import {IRiyzoSpoke} from "src/interfaces/spoke/IRiyzoSpoke.sol";

/// @dev Minimal mock vault that exposes poolId, trancheId, asset, share
contract MockVault {
    uint64 public poolId;
    bytes16 public trancheId;
    address public asset;
    address public share;

    // Track callbacks
    uint256 public depositClaimableCount;
    uint256 public redeemClaimableCount;
    uint256 public cancelDepositClaimableCount;
    uint256 public cancelRedeemClaimableCount;

    constructor(uint64 _poolId, bytes16 _trancheId, address _asset, address _share) {
        poolId = _poolId;
        trancheId = _trancheId;
        asset = _asset;
        share = _share;
    }

    function onDepositClaimable(address, uint256, uint256) external {
        depositClaimableCount++;
    }

    function onRedeemClaimable(address, uint256, uint256) external {
        redeemClaimableCount++;
    }

    function onCancelDepositClaimable(address, uint256) external {
        cancelDepositClaimableCount++;
    }

    function onCancelRedeemClaimable(address, uint256) external {
        cancelRedeemClaimableCount++;
    }

    function onRedeemRequest(address, address, uint256) external {}
}

/// @dev Minimal mock tranche token with transfer restriction checks
contract MockTranche {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public restrictionResult = true;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function setRestrictionResult(bool _result) external {
        restrictionResult = _result;
    }

    function checkTransferRestriction(address, address, uint256) external view returns (bool) {
        return restrictionResult;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function authTransferFrom(address, address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function hook() external pure returns (address) {
        return address(0);
    }
}

/// @dev Minimal mock spoke that stores prices and supports getPrice/getPool/getShareClass/getVault/queueXxx
contract MockSpoke {
    mapping(uint64 => mapping(bytes16 => IRiyzoSpoke.ShareClassState)) public shareClasses;
    mapping(uint64 => IRiyzoSpoke.PoolState) public pools;
    mapping(uint64 => mapping(bytes16 => mapping(address => address))) public vaults;

    uint256 public depositRequestCount;
    uint256 public redeemRequestCount;
    uint256 public cancelDepositCount;
    uint256 public cancelRedeemCount;

    address public lastQueueUser;
    uint128 public lastQueueAmount;

    function setPrice(uint64 poolId, bytes16 scId, uint128 price, uint64 timestamp) external {
        shareClasses[poolId][scId].latestPrice = price;
        shareClasses[poolId][scId].priceTimestamp = timestamp;
    }

    function setPool(uint64 poolId, address currency) external {
        pools[poolId] = IRiyzoSpoke.PoolState({exists: true, poolId: poolId, currency: currency, isActive: true});
    }

    function setShareClass(uint64 poolId, bytes16 scId, address shareToken) external {
        shareClasses[poolId][scId] = IRiyzoSpoke.ShareClassState({
            exists: true,
            scId: scId,
            shareToken: shareToken,
            latestPrice: shareClasses[poolId][scId].latestPrice,
            priceTimestamp: shareClasses[poolId][scId].priceTimestamp
        });
    }

    function setVault(uint64 poolId, bytes16 scId, address asset, address vault) external {
        vaults[poolId][scId][asset] = vault;
    }

    function getPrice(uint64 poolId, bytes16 scId) external view returns (uint128, uint64) {
        return (shareClasses[poolId][scId].latestPrice, shareClasses[poolId][scId].priceTimestamp);
    }

    function getPool(uint64 poolId) external view returns (IRiyzoSpoke.PoolState memory) {
        return pools[poolId];
    }

    function getShareClass(uint64 poolId, bytes16 scId) external view returns (IRiyzoSpoke.ShareClassState memory) {
        return shareClasses[poolId][scId];
    }

    function getVault(uint64 poolId, bytes16 scId, address asset) external view returns (address) {
        return vaults[poolId][scId][asset];
    }

    function queueDepositRequest(uint64, bytes16, address user, uint128 amount) external {
        depositRequestCount++;
        lastQueueUser = user;
        lastQueueAmount = amount;
    }

    function queueRedeemRequest(uint64, bytes16, address user, uint128 amount) external {
        redeemRequestCount++;
        lastQueueUser = user;
        lastQueueAmount = amount;
    }

    function queueCancelDeposit(uint64, bytes16, address user) external {
        cancelDepositCount++;
        lastQueueUser = user;
    }

    function queueCancelRedeem(uint64, bytes16, address user) external {
        cancelRedeemCount++;
        lastQueueUser = user;
    }
}

/// @title SpokeInvestmentManagerTest
contract SpokeInvestmentManagerTest is Test {
    SpokeInvestmentManager public manager;
    MockVault public vault;
    MockTranche public shareToken;
    MockSpoke public spoke;
    MockEscrowSimple public escrow;
    MockERC20Simple public usdc;

    address public admin = address(this);
    address public user1 = address(0xA1);
    address public user2 = address(0xA2);

    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));
    uint128 public constant ASSET_ID = 1;

    function setUp() public {
        // Deploy mocks
        usdc = new MockERC20Simple("USDC", "USDC", 6);
        shareToken = new MockTranche("Senior", "SR", 18);
        escrow = new MockEscrowSimple();
        spoke = new MockSpoke();

        // Deploy vault
        vault = new MockVault(POOL_ID, SC_ID, address(usdc), address(shareToken));

        // Deploy SpokeInvestmentManager
        manager = new SpokeInvestmentManager(address(escrow), admin);
        manager.file("spoke", address(spoke));

        // Setup spoke mock state
        spoke.setPool(POOL_ID, address(usdc));
        spoke.setShareClass(POOL_ID, SC_ID, address(shareToken));
        spoke.setVault(POOL_ID, SC_ID, address(usdc), address(vault));
        spoke.setPrice(POOL_ID, SC_ID, 1e18, uint64(block.timestamp));

        // Give vault auth on manager (vault calls manager)
        manager.rely(address(vault));

        // Approve escrow to transfer share tokens to manager
        vm.startPrank(address(escrow));
        shareToken.approve(address(manager), type(uint256).max);
        usdc.approve(address(manager), type(uint256).max);
        vm.stopPrank();

        // Fund escrow with USDC for redeem claims
        usdc.mint(address(escrow), 1_000_000e6);
    }

    // ============================================================
    // CONFIGURATION TESTS
    // ============================================================

    function test_file() public {
        address newSpoke = address(0x1234);
        manager.file("spoke", newSpoke);
        assertEq(address(manager.spoke()), newSpoke);
    }

    function test_file_revert_unrecognized() public {
        vm.expectRevert("SpokeInvestmentManager/file-unrecognized-param");
        manager.file("unknown", address(0x1));
    }

    function test_file_revert_unauthorized() public {
        vm.prank(address(0x999));
        vm.expectRevert("Auth/not-authorized");
        manager.file("spoke", address(0x1));
    }

    // ============================================================
    // REQUEST DEPOSIT TESTS
    // ============================================================

    function test_requestDeposit() public {
        bool success = manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        assertTrue(success);
        assertEq(manager.pendingDepositRequest(address(vault), user1), 100e6);
        assertEq(spoke.depositRequestCount(), 1);
        assertEq(spoke.lastQueueUser(), user1);
        assertEq(spoke.lastQueueAmount(), 100e6);
    }

    function test_requestDeposit_revert_zero() public {
        vm.expectRevert("SpokeInvestmentManager/zero-amount-not-allowed");
        manager.requestDeposit(address(vault), 0, user1, address(0), address(0));
    }

    function test_requestDeposit_revert_cancelPending() public {
        // Create a pending deposit first, then set cancel pending
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        // cancelDepositRequest requires auth from vault
        manager.cancelDepositRequest(address(vault), user1, address(0));

        vm.expectRevert("SpokeInvestmentManager/cancellation-is-pending");
        manager.requestDeposit(address(vault), 50e6, user1, address(0), address(0));
    }

    function test_requestDeposit_revert_transferNotAllowed() public {
        shareToken.setRestrictionResult(false);
        vm.expectRevert("SpokeInvestmentManager/transfer-not-allowed");
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
    }

    // ============================================================
    // REQUEST REDEEM TESTS
    // ============================================================

    function test_requestRedeem() public {
        bool success = manager.requestRedeem(address(vault), 50e18, user1, address(0), address(0));
        assertTrue(success);
        assertEq(manager.pendingRedeemRequest(address(vault), user1), 50e18);
        assertEq(spoke.redeemRequestCount(), 1);
    }

    function test_requestRedeem_revert_zero() public {
        vm.expectRevert("SpokeInvestmentManager/zero-amount-not-allowed");
        manager.requestRedeem(address(vault), 0, user1, address(0), address(0));
    }

    // ============================================================
    // CANCEL TESTS
    // ============================================================

    function test_cancelDepositRequest() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        manager.cancelDepositRequest(address(vault), user1, address(0));
        assertTrue(manager.pendingCancelDepositRequest(address(vault), user1));
        assertEq(spoke.cancelDepositCount(), 1);
    }

    function test_cancelDepositRequest_revert_noPending() public {
        vm.expectRevert("SpokeInvestmentManager/no-pending-deposit-request");
        manager.cancelDepositRequest(address(vault), user1, address(0));
    }

    function test_cancelRedeemRequest() public {
        manager.requestRedeem(address(vault), 50e18, user1, address(0), address(0));
        manager.cancelRedeemRequest(address(vault), user1, address(0));
        assertTrue(manager.pendingCancelRedeemRequest(address(vault), user1));
        assertEq(spoke.cancelRedeemCount(), 1);
    }

    function test_cancelRedeemRequest_revert_noPending() public {
        vm.expectRevert("SpokeInvestmentManager/no-pending-redeem-request");
        manager.cancelRedeemRequest(address(vault), user1, address(0));
    }

    // ============================================================
    // FULFILL DEPOSIT TESTS
    // ============================================================

    function test_fulfillDepositRequest() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));

        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);

        assertEq(manager.maxMint(address(vault), user1), 100e18);
        assertEq(manager.pendingDepositRequest(address(vault), user1), 0);
        assertEq(shareToken.balanceOf(address(escrow)), 100e18);
        assertEq(vault.depositClaimableCount(), 1);
    }

    function test_fulfillDepositRequest_partial() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));

        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 50e6, 50e18);

        assertEq(manager.maxMint(address(vault), user1), 50e18);
        assertEq(manager.pendingDepositRequest(address(vault), user1), 50e6);
    }

    function test_fulfillDepositRequest_revert_noPending() public {
        vm.expectRevert("SpokeInvestmentManager/no-pending-deposit-request");
        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);
    }

    // ============================================================
    // FULFILL REDEEM TESTS
    // ============================================================

    function test_fulfillRedeemRequest() public {
        manager.requestRedeem(address(vault), 100e18, user1, address(0), address(0));

        // Mint shares to escrow first (simulating shares locked on requestRedeem)
        shareToken.mint(address(escrow), 100e18);

        manager.fulfillRedeemRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);

        assertEq(manager.maxWithdraw(address(vault), user1), 100e6);
        assertEq(manager.pendingRedeemRequest(address(vault), user1), 0);
        assertEq(vault.redeemClaimableCount(), 1);
    }

    function test_fulfillRedeemRequest_revert_noPending() public {
        vm.expectRevert("SpokeInvestmentManager/no-pending-redeem-request");
        manager.fulfillRedeemRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);
    }

    // ============================================================
    // FULFILL CANCEL TESTS
    // ============================================================

    function test_fulfillCancelDepositRequest() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        manager.cancelDepositRequest(address(vault), user1, address(0));

        manager.fulfillCancelDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e6);

        assertEq(manager.claimableCancelDepositRequest(address(vault), user1), 100e6);
        assertEq(manager.pendingDepositRequest(address(vault), user1), 0);
        assertFalse(manager.pendingCancelDepositRequest(address(vault), user1));
        assertEq(vault.cancelDepositClaimableCount(), 1);
    }

    function test_fulfillCancelDepositRequest_revert_noPendingCancel() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        vm.expectRevert("SpokeInvestmentManager/no-pending-cancel-deposit-request");
        manager.fulfillCancelDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e6);
    }

    function test_fulfillCancelRedeemRequest() public {
        manager.requestRedeem(address(vault), 100e18, user1, address(0), address(0));
        manager.cancelRedeemRequest(address(vault), user1, address(0));

        manager.fulfillCancelRedeemRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e18);

        assertEq(manager.claimableCancelRedeemRequest(address(vault), user1), 100e18);
        assertEq(manager.pendingRedeemRequest(address(vault), user1), 0);
        assertFalse(manager.pendingCancelRedeemRequest(address(vault), user1));
        assertEq(vault.cancelRedeemClaimableCount(), 1);
    }

    // ============================================================
    // CLAIM (DEPOSIT/MINT) TESTS
    // ============================================================

    function test_deposit_claim() public {
        // Setup: request + fulfill
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);

        // Claim via deposit
        uint256 shares = manager.deposit(address(vault), 100e6, user1, user1);
        assertEq(shares, 100e18);
        assertEq(shareToken.balanceOf(user1), 100e18);
        assertEq(manager.maxMint(address(vault), user1), 0);
    }

    function test_mint_claim() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);

        uint256 assets = manager.mint(address(vault), 100e18, user1, user1);
        assertEq(assets, 100e6);
        assertEq(shareToken.balanceOf(user1), 100e18);
    }

    function test_deposit_revert_exceedsMax() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);

        vm.expectRevert("SpokeInvestmentManager/exceeds-max-deposit");
        manager.deposit(address(vault), 200e6, user1, user1);
    }

    // ============================================================
    // CLAIM (REDEEM/WITHDRAW) TESTS
    // ============================================================

    function test_withdraw_claim() public {
        manager.requestRedeem(address(vault), 100e18, user1, address(0), address(0));
        shareToken.mint(address(escrow), 100e18);
        manager.fulfillRedeemRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);

        uint256 shares = manager.withdraw(address(vault), 100e6, user1, user1);
        assertGt(shares, 0);
        assertEq(usdc.balanceOf(user1), 100e6);
        assertEq(manager.maxWithdraw(address(vault), user1), 0);
    }

    function test_redeem_claim() public {
        manager.requestRedeem(address(vault), 100e18, user1, address(0), address(0));
        shareToken.mint(address(escrow), 100e18);
        manager.fulfillRedeemRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);

        uint256 maxRedeemable = manager.maxRedeem(address(vault), user1);
        uint256 assets = manager.redeem(address(vault), maxRedeemable, user1, user1);
        assertEq(assets, 100e6);
    }

    // ============================================================
    // CLAIM CANCEL TESTS
    // ============================================================

    function test_claimCancelDepositRequest() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        manager.cancelDepositRequest(address(vault), user1, address(0));
        manager.fulfillCancelDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e6);

        uint256 assets = manager.claimCancelDepositRequest(address(vault), user1, user1);
        assertEq(assets, 100e6);
        assertEq(usdc.balanceOf(user1), 100e6);
        assertEq(manager.claimableCancelDepositRequest(address(vault), user1), 0);
    }

    function test_claimCancelRedeemRequest() public {
        manager.requestRedeem(address(vault), 100e18, user1, address(0), address(0));
        manager.cancelRedeemRequest(address(vault), user1, address(0));
        manager.fulfillCancelRedeemRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e18);

        // Shares need to be in escrow for claim
        shareToken.mint(address(escrow), 100e18);

        uint256 shares = manager.claimCancelRedeemRequest(address(vault), user1, user1);
        assertEq(shares, 100e18);
        assertEq(shareToken.balanceOf(user1), 100e18);
    }

    // ============================================================
    // VIEW FUNCTION TESTS
    // ============================================================

    function test_convertToShares() public view {
        // Price = 1e18, USDC 6 decimals, shares 18 decimals
        uint256 shares = manager.convertToShares(address(vault), 100e6);
        assertEq(shares, 100e18);
    }

    function test_convertToAssets() public view {
        uint256 assets = manager.convertToAssets(address(vault), 100e18);
        assertEq(assets, 100e6);
    }

    function test_convertToShares_zeroPrice() public {
        spoke.setPrice(POOL_ID, SC_ID, 0, 0);
        uint256 shares = manager.convertToShares(address(vault), 100e6);
        assertEq(shares, 0);
    }

    function test_priceLastUpdated() public {
        uint64 ts = uint64(block.timestamp);
        spoke.setPrice(POOL_ID, SC_ID, 1e18, ts);
        assertEq(manager.priceLastUpdated(address(vault)), ts);
    }

    function test_maxDeposit_restricted() public {
        // Request and fulfill with restrictions enabled
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));
        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 100e6, 100e18);

        // Now disable restrictions - maxDeposit/maxMint should return 0
        shareToken.setRestrictionResult(false);
        assertEq(manager.maxDeposit(address(vault), user1), 0);
        assertEq(manager.maxMint(address(vault), user1), 0);
    }

    // ============================================================
    // HANDLE REVERT TEST
    // ============================================================

    function test_handle_reverts() public {
        vm.expectRevert("SpokeInvestmentManager/messages-go-through-spoke-handler");
        manager.handle("");
    }

    // ============================================================
    // MULTIPLE FULFILLMENTS TEST
    // ============================================================

    function test_multiple_partial_fulfillments() public {
        manager.requestDeposit(address(vault), 100e6, user1, address(0), address(0));

        // First partial fulfillment
        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 40e6, 40e18);
        assertEq(manager.maxMint(address(vault), user1), 40e18);
        assertEq(manager.pendingDepositRequest(address(vault), user1), 60e6);

        // Second partial fulfillment
        manager.fulfillDepositRequest(POOL_ID, SC_ID, user1, ASSET_ID, 60e6, 60e18);
        assertEq(manager.maxMint(address(vault), user1), 100e18);
        assertEq(manager.pendingDepositRequest(address(vault), user1), 0);
    }

    // ============================================================
    // RECOVER TOKENS TEST
    // ============================================================

    function test_recoverTokens() public {
        usdc.mint(address(manager), 500e6);
        manager.recoverTokens(address(usdc), admin, 500e6);
        assertEq(usdc.balanceOf(admin), 500e6);
    }
}

/// @dev Simple mock for the escrow (just holds tokens)
contract MockEscrowSimple {
    // No-op - tokens are held by this address, approvals set in setUp

    }

/// @dev Simple mock ERC20 for tests
contract MockERC20Simple {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
