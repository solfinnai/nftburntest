// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BurnSwapPFP} from "../src/BurnSwapPFP.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract BurnSwapPFPTest is Test {
    BurnSwapPFP nft;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant MAX = 555;

    event Swapped(address indexed holder, uint256 indexed burnedId, uint256 indexed newId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function setUp() public {
        nft = new BurnSwapPFP("Burn Swap PFP", "BSP", owner, "ipfs://cid/", 444, 1);
    }

    // ---- helpers ----------------------------------------------------------

    function _openMint() internal {
        vm.prank(owner);
        nft.setMintOpen(true);
    }

    function _openSwap() internal {
        vm.prank(owner);
        nft.setSwapOpen(true);
    }

    function _mintOne(address who) internal returns (uint256 id) {
        vm.prank(who);
        nft.mint(1);
        id = nft.tokensOfOwner(who)[0];
    }

    function _firstUnmintedExcept(uint256 skip) internal view returns (uint256) {
        uint256[] memory ids = nft.unmintedTokenIds();
        return ids[0] == skip ? ids[1] : ids[0];
    }

    // ---- deployment -------------------------------------------------------

    function test_InitialState() public view {
        assertEq(nft.name(), "Burn Swap PFP");
        assertEq(nft.symbol(), "BSP");
        assertEq(nft.owner(), owner);
        assertEq(nft.MAX_SUPPLY(), MAX);
        assertEq(nft.unmintedCount(), MAX);
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.publicMintCap(), 444);
        assertEq(nft.maxPerWallet(), 1);
        assertFalse(nft.mintOpen());
        assertFalse(nft.swapOpen());

        uint256[] memory ids = nft.unmintedTokenIds();
        assertEq(ids.length, MAX);
        for (uint256 i; i < MAX; ++i) {
            assertEq(ids[i], i + 1);
        }
    }

    function test_RevertWhen_CapAboveSupply() public {
        vm.expectRevert(BurnSwapPFP.InvalidPublicMintCap.selector);
        new BurnSwapPFP("x", "x", owner, "", MAX + 1, 1);
    }

    // ---- mint -------------------------------------------------------------

    function test_Mint() public {
        _openMint();
        uint256 id = _mintOne(alice);

        assertGe(id, 1);
        assertLe(id, MAX);
        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.mintedBy(alice), 1);
        assertEq(nft.publicMinted(), 1);
        assertEq(nft.unmintedCount(), MAX - 1);
        assertEq(nft.totalSupply(), 1);
        assertFalse(nft.isUnminted(id));
        assertEq(uint8(nft.tokenState(id)), uint8(BurnSwapPFP.TokenState.Owned));
    }

    function test_MintMultipleGivesDistinctIds() public {
        vm.startPrank(owner);
        nft.setMaxPerWallet(20);
        nft.setMintOpen(true);
        vm.stopPrank();

        vm.prank(alice);
        nft.mint(20);

        uint256[] memory ids = nft.tokensOfOwner(alice);
        assertEq(ids.length, 20);
        for (uint256 i = 1; i < ids.length; ++i) {
            assertGt(ids[i], ids[i - 1]); // ascending and therefore distinct
        }
        assertEq(nft.unmintedCount(), MAX - 20);
    }

    function test_RevertWhen_MintClosed() public {
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.MintClosed.selector);
        nft.mint(1);
    }

    function test_RevertWhen_MintZero() public {
        _openMint();
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.ZeroQuantity.selector);
        nft.mint(0);
    }

    function test_RevertWhen_MintOverWalletLimit() public {
        _openMint();
        _mintOne(alice);
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.ExceedsWalletLimit.selector);
        nft.mint(1);
    }

    function test_WalletLimitCountsMintsNotBalance() public {
        _openMint();
        uint256 id = _mintOne(alice);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);

        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.ExceedsWalletLimit.selector);
        nft.mint(1);
    }

    function test_RevertWhen_MintOverPublicCap() public {
        vm.startPrank(owner);
        nft.setPublicMintCap(2);
        nft.setMintOpen(true);
        vm.stopPrank();

        _mintOne(alice);
        _mintOne(bob);

        vm.prank(makeAddr("carol"));
        vm.expectRevert(BurnSwapPFP.ExceedsPublicMintCap.selector);
        nft.mint(1);
    }

    function test_PublicCapKeepsReserveForSwaps() public {
        vm.startPrank(owner);
        nft.setPublicMintCap(MAX - 5);
        nft.setMaxPerWallet(MAX);
        nft.setMintOpen(true);
        vm.stopPrank();

        vm.prank(alice);
        nft.mint(MAX - 5);

        assertEq(nft.unmintedCount(), 5);
        assertEq(nft.unmintedTokenIds().length, 5);
    }

    function test_RevertWhen_PoolExhaustedByAirdrops() public {
        uint256[] memory ids = new uint256[](MAX - 1);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = i + 1;
        }
        vm.startPrank(owner);
        nft.airdrop(owner, ids);
        nft.setMaxPerWallet(5);
        nft.setMintOpen(true);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.PoolExhausted.selector);
        nft.mint(2);

        vm.prank(alice);
        nft.mint(1);
        assertEq(nft.ownerOf(MAX), alice);
        assertEq(nft.unmintedCount(), 0);
    }

    function test_FullMintOut() public {
        vm.startPrank(owner);
        nft.setPublicMintCap(MAX);
        nft.setMintOpen(true);
        vm.stopPrank();

        for (uint256 i; i < MAX; ++i) {
            address minter = vm.addr(i + 1);
            vm.prank(minter);
            nft.mint(1);
            vm.roll(block.number + 1);
        }

        assertEq(nft.unmintedCount(), 0);
        assertEq(nft.totalSupply(), MAX);
        assertEq(nft.unmintedTokenIds().length, 0);
        for (uint256 id = 1; id <= MAX; ++id) {
            assertEq(uint8(nft.tokenState(id)), uint8(BurnSwapPFP.TokenState.Owned));
        }
    }

    // ---- swap -------------------------------------------------------------

    function test_Swap() public {
        _openMint();
        _openSwap();
        uint256 oldId = _mintOne(alice);
        uint256 newId = _firstUnmintedExcept(oldId);

        vm.expectEmit(address(nft));
        emit Swapped(alice, oldId, newId);
        vm.prank(alice);
        nft.swap(oldId, newId);

        assertEq(nft.ownerOf(newId), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalBurned(), 1);
        assertEq(nft.unmintedCount(), MAX - 2);
        assertEq(nft.totalSupply(), 1);
        assertEq(uint8(nft.tokenState(oldId)), uint8(BurnSwapPFP.TokenState.Burned));
        assertEq(uint8(nft.tokenState(newId)), uint8(BurnSwapPFP.TokenState.Owned));
        assertFalse(nft.isUnminted(oldId));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, oldId));
        nft.ownerOf(oldId);
    }

    function test_SwapDoesNotUseMintAllowance() public {
        _openMint();
        _openSwap();
        uint256 id = _mintOne(alice);
        for (uint256 i; i < 10; ++i) {
            uint256 next = _firstUnmintedExcept(id);
            vm.prank(alice);
            nft.swap(id, next);
            id = next;
        }
        assertEq(nft.mintedBy(alice), 1);
        assertEq(nft.publicMinted(), 1);
        assertEq(nft.totalBurned(), 10);
    }

    function test_SwapReserveStillAvailableAfterPublicCap() public {
        vm.startPrank(owner);
        nft.setPublicMintCap(1);
        nft.setMintOpen(true);
        nft.setSwapOpen(true);
        vm.stopPrank();

        uint256 id = _mintOne(alice);
        uint256 target = id == MAX ? 1 : MAX;
        vm.prank(alice);
        nft.swap(id, target);
        assertEq(nft.ownerOf(target), alice);
    }

    function test_RevertWhen_SwapClosed() public {
        _openMint();
        uint256 id = _mintOne(alice);
        uint256 target = _firstUnmintedExcept(id);
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.SwapClosed.selector);
        nft.swap(id, target);
    }

    function test_RevertWhen_SwapNotOwner() public {
        _openMint();
        _openSwap();
        uint256 id = _mintOne(alice);
        uint256 target = _firstUnmintedExcept(id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotTokenOwner.selector, id));
        nft.swap(id, target);
    }

    function test_RevertWhen_SwapByApprovedOperator() public {
        _openMint();
        _openSwap();
        uint256 id = _mintOne(alice);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        uint256 target = _firstUnmintedExcept(id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotTokenOwner.selector, id));
        nft.swap(id, target);
    }

    function test_RevertWhen_SwapForOwnedToken() public {
        _openMint();
        _openSwap();
        uint256 a = _mintOne(alice);
        uint256 b = _mintOne(bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotUnminted.selector, b));
        nft.swap(a, b);
    }

    function test_RevertWhen_SwapForSelf() public {
        _openMint();
        _openSwap();
        uint256 id = _mintOne(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotUnminted.selector, id));
        nft.swap(id, id);
    }

    function test_RevertWhen_SwapForBurnedToken() public {
        _openMint();
        _openSwap();
        uint256 a = _mintOne(alice);
        uint256 a2 = _firstUnmintedExcept(a);
        vm.prank(alice);
        nft.swap(a, a2);

        uint256 b = _mintOne(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotUnminted.selector, a));
        nft.swap(b, a);
    }

    function test_RevertWhen_SwapForOutOfRangeId() public {
        _openMint();
        _openSwap();
        uint256 id = _mintOne(alice);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotUnminted.selector, 0));
        nft.swap(id, 0);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotUnminted.selector, MAX + 1));
        nft.swap(id, MAX + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_SwapWithPoolEmpty() public {
        vm.startPrank(owner);
        nft.setPublicMintCap(MAX);
        nft.setMaxPerWallet(MAX);
        nft.setMintOpen(true);
        nft.setSwapOpen(true);
        vm.stopPrank();

        vm.prank(alice);
        nft.mint(MAX);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotUnminted.selector, 2));
        nft.swap(1, 2);
    }

    // ---- airdrop ----------------------------------------------------------

    function test_Airdrop() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 555;
        ids[2] = 100;
        vm.prank(owner);
        nft.airdrop(bob, ids);

        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(555), bob);
        assertEq(nft.ownerOf(100), bob);
        assertEq(nft.unmintedCount(), MAX - 3);
        assertEq(nft.publicMinted(), 0);
        assertFalse(nft.isUnminted(1));
        assertFalse(nft.isUnminted(555));
        assertFalse(nft.isUnminted(100));
    }

    function test_RevertWhen_AirdropTakenId() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 7;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotUnminted.selector, 7));
        nft.airdrop(bob, ids);
    }

    function test_RevertWhen_AirdropNotOwner() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.airdrop(alice, ids);
    }

    // ---- metadata ---------------------------------------------------------

    function test_TokenURI() public {
        _openMint();
        uint256 id = _mintOne(alice);
        assertEq(nft.tokenURI(id), string.concat("ipfs://cid/", vm.toString(id), ".json"));
    }

    function test_PreviewURIWorksForUnminted() public view {
        assertEq(nft.previewURI(42), "ipfs://cid/42.json");
    }

    function test_RevertWhen_TokenURIUnminted() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        nft.tokenURI(42);
    }

    function test_RevertWhen_PreviewURIOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        nft.previewURI(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, MAX + 1));
        nft.previewURI(MAX + 1);
    }

    function test_SetBaseURI() public {
        vm.expectEmit(address(nft));
        emit BatchMetadataUpdate(1, MAX);
        vm.prank(owner);
        nft.setBaseURI("https://example.com/meta/", "");
        assertEq(nft.previewURI(9), "https://example.com/meta/9");
    }

    function test_EmptyBaseURI() public {
        vm.prank(owner);
        nft.setBaseURI("", ".json");
        assertEq(nft.previewURI(9), "");
    }

    function test_SupportsInterface() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(nft.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(nft.supportsInterface(0x49064906)); // ERC4906
        assertFalse(nft.supportsInterface(0xffffffff));
    }

    // ---- admin ------------------------------------------------------------

    function test_RevertWhen_SettersNotOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        nft.setMintOpen(true);
        vm.expectRevert(err);
        nft.setSwapOpen(true);
        vm.expectRevert(err);
        nft.setPublicMintCap(1);
        vm.expectRevert(err);
        nft.setMaxPerWallet(5);
        vm.expectRevert(err);
        nft.setBaseURI("x", "");
        vm.stopPrank();
    }

    function test_RevertWhen_CapBelowMinted() public {
        vm.startPrank(owner);
        nft.setMaxPerWallet(3);
        nft.setMintOpen(true);
        vm.stopPrank();
        vm.prank(alice);
        nft.mint(3);

        vm.startPrank(owner);
        vm.expectRevert(BurnSwapPFP.InvalidPublicMintCap.selector);
        nft.setPublicMintCap(2);
        vm.expectRevert(BurnSwapPFP.InvalidPublicMintCap.selector);
        nft.setPublicMintCap(MAX + 1);
        nft.setPublicMintCap(3);
        vm.stopPrank();
        assertEq(nft.publicMintCap(), 3);
    }

    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        nft.transferOwnership(bob);
        assertEq(nft.owner(), owner);
        vm.prank(bob);
        nft.acceptOwnership();
        assertEq(nft.owner(), bob);
    }

    // ---- fuzz -------------------------------------------------------------

    /// Random sequences of airdrops (picked IDs), mints (random IDs) and swaps keep the pool consistent.
    function testFuzz_PoolStaysConsistent(uint256 seed) public {
        vm.startPrank(owner);
        nft.setPublicMintCap(MAX);
        nft.setMaxPerWallet(MAX);
        nft.setMintOpen(true);
        nft.setSwapOpen(true);
        vm.stopPrank();

        for (uint256 step; step < 60; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 unminted = nft.unmintedCount();
            if (unminted == 0) break;

            uint256 action = seed % 3;
            if (action == 0) {
                vm.prank(alice);
                nft.mint(1 + (seed >> 8) % (unminted < 4 ? unminted : 4));
            } else if (action == 1) {
                uint256[] memory ids = new uint256[](1);
                ids[0] = nft.unmintedTokenIds()[(seed >> 8) % unminted];
                vm.prank(owner);
                nft.airdrop(bob, ids);
            } else {
                uint256[] memory held = nft.tokensOfOwner(alice);
                if (held.length == 0) continue;
                uint256 burnId = held[(seed >> 8) % held.length];
                uint256 newId = nft.unmintedTokenIds()[(seed >> 16) % unminted];
                vm.prank(alice);
                nft.swap(burnId, newId);
            }
            vm.roll(block.number + 1);
        }

        _assertConsistent();
    }

    function _assertConsistent() internal view {
        uint256[] memory pool = nft.unmintedTokenIds();
        assertEq(pool.length, nft.unmintedCount());

        bool[] memory inPool = new bool[](MAX + 1);
        for (uint256 i; i < pool.length; ++i) {
            assertGe(pool[i], 1);
            assertLe(pool[i], MAX);
            assertFalse(inPool[pool[i]], "duplicate in pool");
            inPool[pool[i]] = true;
        }

        uint256 owned;
        uint256 burned;
        for (uint256 id = 1; id <= MAX; ++id) {
            BurnSwapPFP.TokenState s = nft.tokenState(id);
            assertEq(nft.isUnminted(id), inPool[id]);
            if (inPool[id]) {
                assertEq(uint8(s), uint8(BurnSwapPFP.TokenState.Unminted));
            } else if (s == BurnSwapPFP.TokenState.Owned) {
                ++owned;
            } else {
                ++burned;
            }
        }
        assertEq(owned, nft.totalSupply());
        assertEq(burned, nft.totalBurned());
        assertEq(owned + burned + pool.length, MAX);
        assertEq(nft.balanceOf(alice) + nft.balanceOf(bob), owned);
    }
}
