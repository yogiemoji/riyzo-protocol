// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultRegistry} from "src/core/spoke/VaultRegistry.sol";
import {IVaultRegistry} from "src/interfaces/spoke/IVaultRegistry.sol";
import {MockVaultFactory} from "test/mocks/MockVaultFactory.sol";
import {MockTrancheFactory} from "test/mocks/MockTrancheFactory.sol";
import {MockEscrow} from "test/mocks/MockEscrow.sol";

/// @title VaultRegistryTest - Unit tests for VaultRegistry.sol
contract VaultRegistryTest is Test {
    VaultRegistry public vaultRegistry;
    MockVaultFactory public vaultFactory;
    MockTrancheFactory public trancheFactory;
    MockEscrow public escrow;

    address public admin = address(this);
    address public root = address(0x1001);
    address public investmentManager = address(0x1234);
    address public usdc = address(0x2001);
    address public unauthorized = address(0x999);

    uint64 public constant POOL_ID = 1;
    bytes16 public constant SC_ID = bytes16(uint128(1));

    function setUp() public {
        // Deploy mocks
        escrow = new MockEscrow();
        vaultFactory = new MockVaultFactory();
        trancheFactory = new MockTrancheFactory();

        // Deploy VaultRegistry
        vaultRegistry = new VaultRegistry(admin, root, address(escrow));

        // Configure factories
        vaultRegistry.file("vaultFactory", address(vaultFactory));
        vaultRegistry.file("trancheFactory", address(trancheFactory));
        vaultRegistry.file("investmentManager", investmentManager);
    }

    // ============================================================
    // CONSTRUCTOR TESTS
    // ============================================================

    function test_constructor() public view {
        assertEq(vaultRegistry.root(), root);
        assertEq(vaultRegistry.escrow(), address(escrow));
        assertEq(vaultRegistry.wards(admin), 1);
    }

    function test_constructor_revert_zeroRoot() public {
        vm.expectRevert("VaultRegistry/zero-root");
        new VaultRegistry(admin, address(0), address(escrow));
    }

    function test_constructor_revert_zeroEscrow() public {
        vm.expectRevert("VaultRegistry/zero-escrow");
        new VaultRegistry(admin, root, address(0));
    }

    // ============================================================
    // CONFIGURATION TESTS
    // ============================================================

    function test_file_vaultFactory() public {
        address newFactory = address(0xF1);
        vaultRegistry.file("vaultFactory", newFactory);
        assertEq(vaultRegistry.vaultFactory(), newFactory);
    }

    function test_file_trancheFactory() public {
        address newFactory = address(0xF2);
        vaultRegistry.file("trancheFactory", newFactory);
        assertEq(vaultRegistry.trancheFactory(), newFactory);
    }

    function test_file_revert_unrecognized() public {
        vm.expectRevert("VaultRegistry/file-unrecognized-param");
        vaultRegistry.file("unknown", address(0x1));
    }

    function test_file_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert("Auth/not-authorized");
        vaultRegistry.file("vaultFactory", address(0x1));
    }

    // ============================================================
    // SHARE TOKEN DEPLOYMENT TESTS
    // ============================================================

    function test_deployShareToken() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior Tranche", "SR", address(0));

        assertEq(vaultRegistry.getShareToken(POOL_ID, SC_ID), shareToken);
        assertEq(trancheFactory.deployCount(), 1);
    }

    function test_deployShareToken_withHook() public {
        address hook = address(0x3001);
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior Tranche", "SR", hook);

        assertEq(vaultRegistry.getShareToken(POOL_ID, SC_ID), shareToken);
    }

    function test_deployShareToken_revert_alreadyExists() public {
        vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior Tranche", "SR", address(0));

        vm.expectRevert(abi.encodeWithSelector(IVaultRegistry.ShareTokenAlreadyExists.selector, POOL_ID, SC_ID));
        vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior Tranche 2", "SR2", address(0));
    }

    function test_deployShareToken_revert_factoryNotSet() public {
        VaultRegistry newRegistry = new VaultRegistry(admin, root, address(escrow));

        vm.expectRevert(abi.encodeWithSelector(IVaultRegistry.FactoryNotSet.selector, "trancheFactory"));
        newRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
    }

    // ============================================================
    // VAULT DEPLOYMENT TESTS
    // ============================================================

    function test_deployVault() public {
        // First deploy share token
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));

        // Then deploy vault
        address vault = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        assertNotEq(vault, address(0));
        assertEq(vaultRegistry.getVault(POOL_ID, SC_ID, usdc), vault);
        assertEq(vaultRegistry.vaultCount(), 1);
    }

    function test_deployVault_metadata() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        address vault = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        IVaultRegistry.VaultMetadata memory metadata = vaultRegistry.getVaultInfo(vault);

        assertEq(metadata.poolId, POOL_ID);
        assertEq(metadata.scId, SC_ID);
        assertEq(metadata.asset, usdc);
        assertEq(metadata.shareToken, shareToken);
        assertFalse(metadata.isActive); // Not active until explicitly activated
        assertGt(metadata.deployedAt, 0);
    }

    function test_deployVault_revert_alreadyExists() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        bytes32 vaultId = keccak256(abi.encodePacked(POOL_ID, SC_ID, usdc));
        vm.expectRevert(abi.encodeWithSelector(IVaultRegistry.VaultAlreadyExists.selector, vaultId));
        vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);
    }

    function test_deployVault_revert_factoryNotSet() public {
        VaultRegistry newRegistry = new VaultRegistry(admin, root, address(escrow));

        vm.expectRevert(abi.encodeWithSelector(IVaultRegistry.FactoryNotSet.selector, "vaultFactory"));
        newRegistry.deployVault(POOL_ID, SC_ID, usdc, address(0x1));
    }

    // ============================================================
    // VAULT LIFECYCLE TESTS
    // ============================================================

    function test_activateVault() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        address vault = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        assertFalse(vaultRegistry.isActiveVault(vault));

        vaultRegistry.activateVault(vault);

        assertTrue(vaultRegistry.isActiveVault(vault));
    }

    function test_activateVault_revert_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultRegistry.VaultNotFound.selector, address(0x123)));
        vaultRegistry.activateVault(address(0x123));
    }

    function test_activateVault_revert_alreadyActive() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        address vault = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);
        vaultRegistry.activateVault(vault);

        vm.expectRevert(abi.encodeWithSelector(IVaultRegistry.VaultAlreadyActive.selector, vault));
        vaultRegistry.activateVault(vault);
    }

    function test_deactivateVault() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        address vault = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);
        vaultRegistry.activateVault(vault);

        vaultRegistry.deactivateVault(vault);

        assertFalse(vaultRegistry.isActiveVault(vault));
    }

    function test_deactivateVault_revert_notActive() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        address vault = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        vm.expectRevert(abi.encodeWithSelector(IVaultRegistry.VaultNotActive.selector, vault));
        vaultRegistry.deactivateVault(vault);
    }

    function test_unlinkVault() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        address vault = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        vaultRegistry.unlinkVault(vault);

        assertEq(vaultRegistry.getVault(POOL_ID, SC_ID, usdc), address(0));
    }

    function test_unlinkVault_revert_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultRegistry.VaultNotFound.selector, address(0x123)));
        vaultRegistry.unlinkVault(address(0x123));
    }

    // ============================================================
    // VIEW FUNCTION TESTS
    // ============================================================

    function test_getVaultsByPool() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        address vault1 = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        address usdt = address(0x2002);
        address vault2 = vaultRegistry.deployVault(POOL_ID, SC_ID, usdt, shareToken);

        address[] memory vaults = vaultRegistry.getVaultsByPool(POOL_ID);

        assertEq(vaults.length, 2);
        assertEq(vaults[0], vault1);
        assertEq(vaults[1], vault2);
    }

    function test_getVaultsByShareClass() public {
        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        address vault1 = vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        address[] memory vaults = vaultRegistry.getVaultsByShareClass(POOL_ID, SC_ID);

        assertEq(vaults.length, 1);
        assertEq(vaults[0], vault1);
    }

    function test_vaultCount() public {
        assertEq(vaultRegistry.vaultCount(), 0);

        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));
        vaultRegistry.deployVault(POOL_ID, SC_ID, usdc, shareToken);

        assertEq(vaultRegistry.vaultCount(), 1);

        address usdt = address(0x2002);
        vaultRegistry.deployVault(POOL_ID, SC_ID, usdt, shareToken);

        assertEq(vaultRegistry.vaultCount(), 2);
    }

    // ============================================================
    // FUZZ TESTS
    // ============================================================

    function testFuzz_deployMultipleVaults(uint8 count) public {
        vm.assume(count > 0 && count <= 10);

        address shareToken = vaultRegistry.deployShareToken(POOL_ID, SC_ID, "Senior", "SR", address(0));

        for (uint8 i = 0; i < count; i++) {
            address asset = address(uint160(i + 1));
            vaultRegistry.deployVault(POOL_ID, SC_ID, asset, shareToken);
        }

        assertEq(vaultRegistry.vaultCount(), count);
        assertEq(vaultRegistry.getVaultsByPool(POOL_ID).length, count);
    }
}
