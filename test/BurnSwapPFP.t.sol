// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {BurnSwapPFP} from "../src/BurnSwapPFP.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract BurnSwapPFPTest is Test {
    BurnSwapPFP nft;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint256 constant MAX = 555;

    event RevealRequested(uint256 indexed requestId, address indexed to, uint256 count, bool isSwap);
    event RevealDelayed(uint256 indexed requestId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function setUp() public {
        nft = new BurnSwapPFP("Burn Swap PFP", "BSP", owner, "ipfs://cid/", 10);
    }

    // ---- helpers ----------------------------------------------------------

    function _open() internal {
        vm.startPrank(owner);
        nft.setMintOpen(true);
        nft.setSwapOpen(true);
        vm.stopPrank();
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
    }

    /// Reveals everything that is pending (after letting the request block finish).
    function _revealAll() internal {
        _nextBlock();
        vm.prank(keeper);
        nft.reveal(type(uint256).max);
        assertEq(nft.nextToReveal(), nft.nextRequestId(), "queue not empty");
    }

    function _mintRevealed(address who, uint256 quantity) internal returns (uint256[] memory) {
        vm.prank(who);
        nft.mint(quantity);
        _revealAll();
        return nft.tokensOfOwner(who);
    }

    function _swap(address who, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(who);
        nft.swap(ids);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    // ---- deployment -------------------------------------------------------

    function test_InitialState() public view {
        assertEq(nft.name(), "Burn Swap PFP");
        assertEq(nft.owner(), owner);
        assertEq(nft.MAX_SUPPLY(), MAX);
        assertEq(nft.unmintedCount(), MAX);
        assertEq(nft.available(), MAX);
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.maxPerWallet(), 10);
        assertFalse(nft.mintOpen());
        assertFalse(nft.swapOpen());

        uint256[] memory ids = nft.unmintedTokenIds();
        assertEq(ids.length, MAX);
        for (uint256 i; i < MAX; ++i) {
            assertEq(ids[i], i + 1);
        }
    }

    // ---- mint -------------------------------------------------------------

    function test_MintIsRevealedInALaterBlock() public {
        _open();
        vm.expectEmit(address(nft));
        emit RevealRequested(0, alice, 3, false);
        vm.prank(alice);
        nft.mint(3);

        // Nothing is minted yet, but the tokens are set aside.
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.pendingOf(alice), 3);
        assertEq(nft.pendingDraws(), 3);
        assertEq(nft.available(), MAX - 3);
        assertEq(nft.unmintedCount(), MAX);
        assertEq(nft.mintedBy(alice), 3);
        assertEq(nft.lastRequestOf(alice), 0);

        // Same block: can't reveal yet.
        assertFalse(nft.isRevealReady(0));
        assertEq(nft.reveal(10), 0);
        assertEq(nft.balanceOf(alice), 0);

        _nextBlock();
        assertTrue(nft.isRevealReady(0));
        vm.prank(keeper); // anyone can reveal, tokens still go to alice
        assertEq(nft.reveal(10), 1);

        uint256[] memory ids = nft.tokensOfOwner(alice);
        assertEq(ids.length, 3);
        assertEq(nft.balanceOf(keeper), 0);
        assertEq(nft.pendingOf(alice), 0);
        assertEq(nft.pendingDraws(), 0);
        assertEq(nft.unmintedCount(), MAX - 3);
        assertEq(nft.totalSupply(), 3);
        for (uint256 i; i < ids.length; ++i) {
            assertFalse(nft.swappedIn(ids[i]));
            assertTrue(nft.canSwap(ids[i]));
            assertFalse(nft.isUnminted(ids[i]));
        }
    }

    function test_TenPerWallet() public {
        _open();
        vm.startPrank(alice);
        nft.mint(4);
        nft.mint(6);
        vm.expectRevert(BurnSwapPFP.ExceedsWalletLimit.selector);
        nft.mint(1);
        vm.stopPrank();
        _revealAll();
        assertEq(nft.balanceOf(alice), 10);
    }

    function test_WalletLimitCountsMintsNotBalance() public {
        _open();
        uint256[] memory ids = _mintRevealed(alice, 10);
        vm.prank(alice);
        nft.transferFrom(alice, bob, ids[0]);

        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.ExceedsWalletLimit.selector);
        nft.mint(1);
    }

    function test_RevertWhen_MintClosed() public {
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.MintClosed.selector);
        nft.mint(1);
    }

    function test_RevertWhen_MintZero() public {
        _open();
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.ZeroQuantity.selector);
        nft.mint(0);
    }

    function test_RevertWhen_MintMoreThanPerTx() public {
        vm.startPrank(owner);
        nft.setMaxPerWallet(100);
        nft.setMintOpen(true);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.TooManyPerTx.selector);
        nft.mint(21);
    }

    function test_MintCanTakeEverything() public {
        vm.startPrank(owner);
        nft.setMaxPerWallet(MAX);
        nft.setMintOpen(true);
        vm.stopPrank();

        vm.startPrank(alice);
        for (uint256 i; i < 27; ++i) {
            nft.mint(20);
        }
        nft.mint(15);
        assertEq(nft.available(), 0);
        vm.expectRevert(BurnSwapPFP.NotEnoughUnminted.selector);
        nft.mint(1);
        vm.stopPrank();

        _revealAll();
        assertEq(nft.balanceOf(alice), MAX);
        assertEq(nft.unmintedCount(), 0);
        assertEq(nft.totalSupply(), MAX);
        for (uint256 id = 1; id <= MAX; ++id) {
            assertEq(nft.ownerOf(id), alice);
        }
    }

    function test_WhateverIsLeftIsTheSwapPool() public {
        _open();
        for (uint256 i; i < 25; ++i) {
            vm.prank(vm.addr(i + 1));
            nft.mint(10);
        }
        _revealAll();
        vm.prank(owner);
        nft.setMintOpen(false);

        assertEq(nft.totalSupply(), 250);
        assertEq(nft.unmintedCount(), MAX - 250);
        assertEq(nft.available(), MAX - 250);
    }

    // ---- swap -------------------------------------------------------------

    function test_Swap() public {
        _open();
        uint256 oldId = _mintRevealed(alice, 1)[0];

        vm.expectEmit(address(nft));
        emit RevealRequested(1, alice, 1, true);
        _swap(alice, oldId);

        // Burned straight away, replacement arrives on reveal.
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.totalBurned(), 1);
        assertEq(uint8(nft.tokenState(oldId)), uint8(BurnSwapPFP.TokenState.Burned));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, oldId));
        nft.ownerOf(oldId);

        _revealAll();
        uint256 newId = nft.tokensOfOwner(alice)[0];
        assertTrue(newId != oldId);
        assertTrue(nft.swappedIn(newId));
        assertFalse(nft.canSwap(newId));
        assertEq(nft.totalSupply(), 1);
        assertEq(nft.unmintedCount(), MAX - 2);
        assertFalse(nft.isUnminted(oldId));
    }

    function test_RevertWhen_SwappingASwappedToken() public {
        _open();
        uint256 oldId = _mintRevealed(alice, 1)[0];
        _swap(alice, oldId);
        _revealAll();
        uint256 newId = nft.tokensOfOwner(alice)[0];

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.AlreadySwapped.selector, newId));
        nft.swap(_one(newId));

        // Still final after changing hands.
        vm.prank(alice);
        nft.transferFrom(alice, bob, newId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.AlreadySwapped.selector, newId));
        nft.swap(_one(newId));
    }

    function test_SwapSeveralAtOnce() public {
        _open();
        uint256[] memory ids = _mintRevealed(alice, 5);

        vm.prank(alice);
        nft.swap(ids);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.totalBurned(), 5);
        assertEq(nft.pendingOf(alice), 5);

        _revealAll();
        uint256[] memory fresh = nft.tokensOfOwner(alice);
        assertEq(fresh.length, 5);
        for (uint256 i; i < fresh.length; ++i) {
            assertTrue(nft.swappedIn(fresh[i]));
            for (uint256 j; j < ids.length; ++j) {
                assertTrue(fresh[i] != ids[j]);
            }
        }
    }

    function test_SwapDoesNotUseMintAllowance() public {
        _open();
        uint256[] memory ids = _mintRevealed(alice, 10);
        vm.prank(alice);
        nft.swap(ids);
        _revealAll();
        assertEq(nft.mintedBy(alice), 10);
        assertEq(nft.publicMinted(), 10);
        assertEq(nft.balanceOf(alice), 10);
    }

    function test_AirdroppedTokensCanBeSwapped() public {
        _open();
        vm.prank(owner);
        nft.airdrop(bob, _one(42));
        assertTrue(nft.canSwap(42));
        _swap(bob, 42);
        _revealAll();
        assertEq(nft.balanceOf(bob), 1);
    }

    function test_RevertWhen_SwapClosed() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        uint256 id = _mintRevealed(alice, 1)[0];
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.SwapClosed.selector);
        nft.swap(_one(id));
    }

    function test_RevertWhen_SwapNothing() public {
        _open();
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.ZeroQuantity.selector);
        nft.swap(new uint256[](0));
    }

    function test_RevertWhen_SwapNotOwner() public {
        _open();
        uint256 id = _mintRevealed(alice, 1)[0];
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotTokenOwner.selector, id));
        nft.swap(_one(id));
    }

    function test_RevertWhen_SwapByApprovedOperator() public {
        _open();
        uint256 id = _mintRevealed(alice, 1)[0];
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotTokenOwner.selector, id));
        nft.swap(_one(id));
    }

    function test_RevertWhen_SwapSameTokenTwiceInOneCall() public {
        _open();
        uint256 id = _mintRevealed(alice, 1)[0];
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BurnSwapPFP.NotTokenOwner.selector, id));
        nft.swap(ids);
    }

    function test_RevertWhen_SwapWithPoolEmpty() public {
        vm.startPrank(owner);
        nft.setMaxPerWallet(MAX);
        nft.setMintOpen(true);
        nft.setSwapOpen(true);
        vm.stopPrank();
        vm.startPrank(alice);
        for (uint256 i; i < 27; ++i) {
            nft.mint(20);
        }
        nft.mint(15);
        vm.stopPrank();
        _revealAll();

        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.NotEnoughUnminted.selector);
        nft.swap(_one(1));
    }

    function test_PendingRequestsReserveTokens() public {
        // Leave exactly 3 unminted, all promised to a pending mint: a swap must not be able to take them.
        vm.startPrank(owner);
        nft.setMaxPerWallet(MAX);
        nft.setMintOpen(true);
        nft.setSwapOpen(true);
        vm.stopPrank();
        vm.startPrank(alice);
        for (uint256 i; i < 27; ++i) {
            nft.mint(20);
        }
        nft.mint(12);
        vm.stopPrank();
        _revealAll();

        vm.prank(bob);
        nft.mint(3);
        assertEq(nft.available(), 0);

        uint256[] memory mine = _one(nft.tokensOfOwner(alice)[0]);
        vm.prank(alice);
        vm.expectRevert(BurnSwapPFP.NotEnoughUnminted.selector);
        nft.swap(mine);

        _revealAll();
        assertEq(nft.balanceOf(bob), 3);
    }

    // ---- reveal: fairness -------------------------------------------------

    /// The result of a request must not depend on who reveals it or how long they wait.
    function test_RevealResultDoesNotDependOnTiming() public {
        _open();
        vm.prank(alice);
        nft.mint(5);
        vm.prank(bob);
        nft.mint(5);

        uint256 snap = vm.snapshotState();
        vm.roll(block.number + 1);
        nft.reveal(10);
        uint256[] memory early = nft.tokensOfOwner(alice);

        vm.revertToState(snap);
        vm.roll(block.number + 200);
        vm.prank(bob);
        nft.reveal(10);
        assertEq(nft.tokensOfOwner(alice), early);
    }

    /// Requests made after yours can't change your result.
    function test_LaterRequestsDoNotAffectEarlierOnes() public {
        _open();
        vm.prank(alice);
        nft.mint(5);

        uint256 snap = vm.snapshotState();
        _revealAll();
        uint256[] memory alone = nft.tokensOfOwner(alice);

        vm.revertToState(snap);
        vm.prank(bob);
        nft.mint(10);
        _nextBlock();
        vm.prank(makeAddr("carol"));
        nft.mint(10);
        _revealAll();
        assertEq(nft.tokensOfOwner(alice), alone);
    }

    function test_RevealIsInOrder() public {
        _open();
        vm.prank(alice);
        nft.mint(2);
        vm.prank(bob);
        nft.mint(2);
        _nextBlock();

        assertEq(nft.reveal(1), 1);
        assertEq(nft.balanceOf(alice), 2);
        assertEq(nft.balanceOf(bob), 0);
        assertEq(nft.nextToReveal(), 1);

        assertEq(nft.reveal(1), 1);
        assertEq(nft.balanceOf(bob), 2);
    }

    function test_RevealStopsAtUnfinishedBlock() public {
        _open();
        vm.prank(alice);
        nft.mint(1);
        _nextBlock();
        vm.prank(bob);
        nft.mint(1);

        assertEq(nft.reveal(10), 1); // bob's request was made in this block
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.balanceOf(bob), 0);
        assertFalse(nft.isRevealReady(1));
    }

    function test_ExpiredRequestGetsFreshEntropy() public {
        _open();
        vm.prank(alice);
        nft.mint(3);
        vm.roll(block.number + 300); // blockhash of the request block is gone

        vm.expectEmit(address(nft));
        emit RevealDelayed(0);
        assertEq(nft.reveal(10), 0);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.getRequest(0).entropyBlock, block.number);

        _nextBlock();
        assertEq(nft.reveal(10), 1);
        assertEq(nft.balanceOf(alice), 3);
    }

    function test_RevealWithNothingPending() public {
        assertEq(nft.reveal(10), 0);
        assertFalse(nft.isRevealReady(0));
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
    }

    function test_RevertWhen_AirdropWhileRevealsPending() public {
        _open();
        vm.prank(alice);
        nft.mint(1);
        vm.prank(owner);
        vm.expectRevert(BurnSwapPFP.RevealsPending.selector);
        nft.airdrop(bob, _one(7));

        _revealAll();
        uint256 free = nft.unmintedTokenIds()[0];
        vm.prank(owner);
        nft.airdrop(bob, _one(free));
        assertEq(nft.ownerOf(free), bob);
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
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.airdrop(alice, _one(7));
    }

    // ---- metadata ---------------------------------------------------------

    function test_TokenURI() public {
        _open();
        uint256 id = _mintRevealed(alice, 1)[0];
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
        nft.setMaxPerWallet(5);
        vm.expectRevert(err);
        nft.setBaseURI("x", "");
        vm.stopPrank();
    }

    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        nft.transferOwnership(bob);
        assertEq(nft.owner(), owner);
        vm.prank(bob);
        nft.acceptOwnership();
        assertEq(nft.owner(), bob);
    }

    // ---- gas --------------------------------------------------------------

    function test_GasOfLargestReveal() public {
        vm.startPrank(owner);
        nft.setMaxPerWallet(20);
        nft.setMintOpen(true);
        vm.stopPrank();
        vm.prank(alice);
        nft.mint(20);
        _nextBlock();
        uint256 before = gasleft();
        nft.reveal(1);
        uint256 used = before - gasleft();
        assertLt(used, 2_000_000);
    }

    // ---- fuzz -------------------------------------------------------------

    /// Random sequences of mints, swaps, reveals and block changes keep the books consistent.
    function testFuzz_StaysConsistent(uint256 seed) public {
        vm.startPrank(owner);
        nft.setMaxPerWallet(MAX);
        nft.setMintOpen(true);
        nft.setSwapOpen(true);
        vm.stopPrank();

        address[3] memory users = [alice, bob, makeAddr("carol")];
        for (uint256 step; step < 60; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address user = users[seed % 3];
            uint256 action = (seed >> 8) % 4;
            uint256 avail = nft.available();

            if (action == 0 && avail > 0) {
                vm.prank(user);
                nft.mint(1 + (seed >> 16) % (avail < 5 ? avail : 5));
            } else if (action == 1 && avail > 0) {
                uint256[] memory held = nft.tokensOfOwner(user);
                uint256 n;
                uint256[] memory pick = new uint256[](held.length);
                for (uint256 i; i < held.length && n < avail && n < 3; ++i) {
                    if (nft.canSwap(held[i])) pick[n++] = held[i];
                }
                if (n == 0) continue;
                assembly {
                    mstore(pick, n)
                }
                vm.prank(user);
                nft.swap(pick);
            } else if (action == 2) {
                vm.prank(user);
                nft.reveal(1 + (seed >> 24) % 3);
            } else {
                vm.roll(block.number + 1 + (seed >> 32) % 3);
            }
        }
        _revealAll();
        _assertConsistent(users);
    }

    function _assertConsistent(address[3] memory users) internal view {
        uint256[] memory pool = nft.unmintedTokenIds();
        assertEq(pool.length, nft.unmintedCount());
        assertEq(nft.pendingDraws(), 0);

        bool[] memory inPool = new bool[](MAX + 1);
        for (uint256 i; i < pool.length; ++i) {
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
                assertFalse(nft.swappedIn(id));
            } else if (s == BurnSwapPFP.TokenState.Owned) {
                ++owned;
            } else {
                ++burned;
                assertFalse(nft.swappedIn(id), "a swapped-in token was burned");
            }
        }
        assertEq(owned, nft.totalSupply());
        assertEq(burned, nft.totalBurned());
        assertEq(owned + burned + pool.length, MAX);
        uint256 balances;
        for (uint256 i; i < users.length; ++i) {
            balances += nft.balanceOf(users[i]);
        }
        assertEq(balances, owned);
    }
}
