// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title BurnSwapPFP
/// @notice A 555 piece PFP collection with a free mint and a random burn-to-swap.
///
///         All token IDs (1..555) start in the "unminted pool".
///         - `mint` is free and gives the caller random IDs from the pool.
///         - `swap` burns tokens the caller owns and gives them the same number of random IDs from the pool.
///           A token received from a swap is final: it can never be swapped (burned) again.
///
///         Burned IDs never return to the pool, so every swap shrinks the collection by one. Whatever the
///         mint leaves unminted is what swaps draw from.
///
///         Randomness works in two steps so nobody can see their result before committing to it:
///         1. `mint` / `swap` records a request (and, for swaps, burns the old tokens right away).
///         2. `reveal` hands out the tokens once the block the request was made in has finished, using that
///            block's hash, which did not exist yet when the request was made. Requests are revealed strictly
///            in order, so the result does not depend on who calls `reveal` or when. Anyone can call it.
///
/// @dev    The pool is an unordered set stored as two lazily initialised mappings, so deployment does not
///         need to write 555 storage slots. An untouched slot `i` holds token ID `i + 1`. Removing an ID moves
///         the last ID in the pool into its slot (swap and pop), so random draws are O(1).
///
///         On Robinhood Chain (Arbitrum Orbit), `block.number` is the parent chain block number (~12s) and
///         `blockhash` covers the last 256 of those (~51 min). A request older than that gets a fresh entropy
///         block instead of being revealed with a guessable value.
contract BurnSwapPFP is ERC721, Ownable2Step, IERC4906 {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 555;
    /// @notice Most tokens a single mint or swap transaction can request. Keeps each reveal's gas bounded.
    uint256 public constant MAX_PER_TX = 20;

    struct Request {
        address to;
        uint16 count;
        bool isSwap;
        uint64 entropyBlock;
    }

    /// @notice Token IDs that have never been minted, including ones already promised to pending requests.
    uint256 public unmintedCount = MAX_SUPPLY;
    /// @notice Tokens promised to requests that have not been revealed yet.
    uint256 public pendingDraws;
    /// @notice Tokens requested through `mint`.
    uint256 public publicMinted;
    /// @notice Maximum number of tokens one wallet may request through `mint`.
    uint256 public maxPerWallet;
    /// @notice Tokens destroyed through `swap`.
    uint256 public totalBurned;

    bool public mintOpen;
    bool public swapOpen;

    string public baseURI;
    string public uriSuffix = ".json";

    /// @notice Tokens each wallet has requested through `mint`.
    mapping(address => uint256) public mintedBy;
    /// @notice Tokens waiting to be revealed for each wallet.
    mapping(address => uint256) public pendingOf;
    /// @notice ID of each wallet's most recent request. Only meaningful while `pendingOf` is non-zero.
    mapping(address => uint256) public lastRequestOf;
    /// @notice True for tokens that came out of a swap. They can't be swapped again.
    mapping(uint256 tokenId => bool) public swappedIn;

    /// @notice ID the next request will get. Requests `nextToReveal .. nextRequestId - 1` are pending.
    uint256 public nextRequestId;
    /// @notice ID of the oldest pending request.
    uint256 public nextToReveal;

    mapping(uint256 requestId => Request) private _requests;

    // Pool storage. 0 means "untouched", see the contract level @dev note.
    mapping(uint256 slot => uint256 tokenId) private _poolTokenAt;
    mapping(uint256 tokenId => uint256 slotPlusOne) private _poolSlotOf;

    enum TokenState {
        Unminted,
        Owned,
        Burned
    }

    event RevealRequested(uint256 indexed requestId, address indexed to, uint256 count, bool isSwap);
    event Revealed(uint256 indexed requestId, address indexed to, uint256[] tokenIds);
    /// @dev The request's entropy block got too old to read, so it was given a new one.
    event RevealDelayed(uint256 indexed requestId);
    event MintOpenSet(bool open);
    event SwapOpenSet(bool open);
    event MaxPerWalletSet(uint256 max);

    error MintClosed();
    error SwapClosed();
    error ZeroQuantity();
    error TooManyPerTx();
    error ExceedsWalletLimit();
    error NotEnoughUnminted();
    error NotTokenOwner(uint256 tokenId);
    error AlreadySwapped(uint256 tokenId);
    error NotUnminted(uint256 tokenId);
    error RevealsPending();

    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner,
        string memory baseURI_,
        uint256 maxPerWallet_
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        baseURI = baseURI_;
        maxPerWallet = maxPerWallet_;
    }

    // ---------------------------------------------------------------------
    // Public actions
    // ---------------------------------------------------------------------

    /// @notice Request `quantity` random tokens for free. They arrive when the request is revealed.
    function mint(uint256 quantity) external {
        if (!mintOpen) revert MintClosed();
        _checkQuantity(quantity);
        if (mintedBy[msg.sender] + quantity > maxPerWallet) revert ExceedsWalletLimit();

        mintedBy[msg.sender] += quantity;
        publicMinted += quantity;
        _request(msg.sender, quantity, false);
    }

    /// @notice Burn `burnIds` (which you must own) now, and get the same number of random unminted tokens when the
    ///         request is revealed. Tokens that came out of a swap can't be swapped again.
    function swap(uint256[] calldata burnIds) external {
        if (!swapOpen) revert SwapClosed();
        uint256 count = burnIds.length;
        _checkQuantity(count);

        for (uint256 i; i < count; ++i) {
            uint256 tokenId = burnIds[i];
            if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
            if (swappedIn[tokenId]) revert AlreadySwapped(tokenId);
            _burn(tokenId);
        }
        totalBurned += count;
        _request(msg.sender, count, true);
    }

    /// @notice Reveal up to `maxRequests` pending requests, oldest first. Anyone can call this; the result of each
    ///         request is the same no matter who reveals it or when.
    /// @return revealed Number of requests revealed.
    function reveal(uint256 maxRequests) external returns (uint256 revealed) {
        uint256 requestId = nextToReveal;
        uint256 end = nextRequestId;

        while (revealed < maxRequests && requestId < end) {
            Request memory r = _requests[requestId];
            if (r.entropyBlock >= block.number) break; // its block hasn't finished yet

            bytes32 entropy = blockhash(r.entropyBlock);
            if (entropy == 0) {
                // Older than 256 blocks. Use a fresh block rather than anything already known.
                // forge-lint: disable-next-line(unsafe-typecast)
                _requests[requestId].entropyBlock = uint64(block.number);
                emit RevealDelayed(requestId);
                break;
            }

            delete _requests[requestId];
            _fulfill(requestId, r, entropy);
            ++requestId;
            ++revealed;
        }

        nextToReveal = requestId;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Tokens that currently exist (minted and not burned). Pending reveals are not counted yet.
    function totalSupply() public view returns (uint256) {
        return MAX_SUPPLY - unmintedCount - totalBurned;
    }

    /// @notice Unminted tokens that are not already promised to a pending request.
    function available() public view returns (uint256) {
        return unmintedCount - pendingDraws;
    }

    /// @notice Whether `reveal` can make progress on `requestId` right now.
    function isRevealReady(uint256 requestId) external view returns (bool) {
        return
            requestId >= nextToReveal && requestId < nextRequestId && _requests[requestId].entropyBlock < block.number;
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        return _requests[requestId];
    }

    /// @notice Whether `tokenId` exists and can still be burned in a swap.
    function canSwap(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0) && !swappedIn[tokenId];
    }

    function isUnminted(uint256 tokenId) public view returns (bool) {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) return false;
        uint256 slot = _slotOf(tokenId);
        return slot < unmintedCount && _tokenAt(slot) == tokenId;
    }

    /// @notice Reverts for IDs outside 1..MAX_SUPPLY.
    function tokenState(uint256 tokenId) external view returns (TokenState) {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) revert ERC721NonexistentToken(tokenId);
        if (isUnminted(tokenId)) return TokenState.Unminted;
        return _ownerOf(tokenId) == address(0) ? TokenState.Burned : TokenState.Owned;
    }

    /// @notice Every unminted token ID, in no particular order.
    function unmintedTokenIds() external view returns (uint256[] memory ids) {
        uint256 count = unmintedCount;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = _tokenAt(i);
        }
    }

    /// @notice Every token ID held by `owner`, ascending. Scans the whole collection, meant for off-chain calls.
    function tokensOfOwner(address owner) external view returns (uint256[] memory ids) {
        uint256 count = balanceOf(owner);
        ids = new uint256[](count);
        uint256 found;
        for (uint256 id = 1; found < count; ++id) {
            if (_ownerOf(id) == owner) ids[found++] = id;
        }
    }

    /// @notice Metadata URI for any ID in the collection, including unminted ones, so a UI can preview the pool.
    function previewURI(uint256 tokenId) public view returns (string memory) {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) revert ERC721NonexistentToken(tokenId);
        if (bytes(baseURI).length == 0) return "";
        return string.concat(baseURI, tokenId.toString(), uriSuffix);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return previewURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------

    function setMintOpen(bool open) external onlyOwner {
        mintOpen = open;
        emit MintOpenSet(open);
    }

    function setSwapOpen(bool open) external onlyOwner {
        swapOpen = open;
        emit SwapOpenSet(open);
    }

    function setMaxPerWallet(uint256 max) external onlyOwner {
        maxPerWallet = max;
        emit MaxPerWalletSet(max);
    }

    function setBaseURI(string calldata baseURI_, string calldata uriSuffix_) external onlyOwner {
        baseURI = baseURI_;
        uriSuffix = uriSuffix_;
        emit BatchMetadataUpdate(1, MAX_SUPPLY);
    }

    /// @notice Mint specific unminted IDs to `to` (team allocation, giveaways). Ignores the mint toggle and wallet
    ///         limit. Only allowed while nothing is waiting to be revealed, so it can't change a pending result.
    function airdrop(address to, uint256[] calldata tokenIds) external onlyOwner {
        if (nextToReveal != nextRequestId) revert RevealsPending();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (!isUnminted(tokenId)) revert NotUnminted(tokenId);
            _removeAt(_slotOf(tokenId));
            _mint(to, tokenId);
        }
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _checkQuantity(uint256 quantity) private view {
        if (quantity == 0) revert ZeroQuantity();
        if (quantity > MAX_PER_TX) revert TooManyPerTx();
        if (quantity > available()) revert NotEnoughUnminted();
    }

    function _request(address to, uint256 count, bool isSwap) private {
        uint256 requestId = nextRequestId++;
        // forge-lint: disable-next-line(unsafe-typecast)
        _requests[requestId] = Request(to, uint16(count), isSwap, uint64(block.number));
        pendingDraws += count;
        pendingOf[to] += count;
        lastRequestOf[to] = requestId;
        emit RevealRequested(requestId, to, count, isSwap);
    }

    /// @dev Uses `_mint`, not `_safeMint`, so a recipient contract can't block the queue by reverting.
    function _fulfill(uint256 requestId, Request memory r, bytes32 entropy) private {
        pendingDraws -= r.count;
        pendingOf[r.to] -= r.count;

        uint256[] memory tokenIds = new uint256[](r.count);
        for (uint256 i; i < r.count; ++i) {
            uint256 rand = uint256(keccak256(abi.encode(entropy, requestId, i)));
            uint256 tokenId = _removeAt(rand % unmintedCount);
            if (r.isSwap) swappedIn[tokenId] = true;
            _mint(r.to, tokenId);
            tokenIds[i] = tokenId;
        }
        emit Revealed(requestId, r.to, tokenIds);
    }

    function _tokenAt(uint256 slot) private view returns (uint256 tokenId) {
        tokenId = _poolTokenAt[slot];
        if (tokenId == 0) tokenId = slot + 1;
    }

    function _slotOf(uint256 tokenId) private view returns (uint256) {
        uint256 slotPlusOne = _poolSlotOf[tokenId];
        return slotPlusOne == 0 ? tokenId - 1 : slotPlusOne - 1;
    }

    /// @dev Removes the ID at `slot` by moving the last ID in the pool into it. Caller checks `slot < unmintedCount`.
    function _removeAt(uint256 slot) private returns (uint256 tokenId) {
        tokenId = _tokenAt(slot);
        uint256 last = unmintedCount - 1;
        if (slot != last) {
            uint256 lastId = _tokenAt(last);
            _poolTokenAt[slot] = lastId;
            _poolSlotOf[lastId] = slot + 1;
        }
        unmintedCount = last;
    }
}
