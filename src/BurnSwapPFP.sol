// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title BurnSwapPFP
/// @notice A 555 piece PFP collection with a free mint and a burn-to-swap mechanic.
///
///         All token IDs (1..555) start in the "unminted pool".
///         - `mint` is free and hands out random IDs from the pool.
///         - `swap` lets a holder burn a token they own and claim any specific ID that is still in the pool.
///
///         Burned IDs never return to the pool, so every swap permanently shrinks the collection by one.
///         Swaps can only happen while the pool still has tokens in it, so `publicMintCap` lets the owner
///         keep part of the collection out of the free mint and reserved for swaps.
///
/// @dev    The pool is an unordered set stored as two lazily initialised mappings, so deployment does not
///         need to write 555 storage slots. An untouched slot `i` holds token ID `i + 1`.
///         Removing an ID moves the last ID in the pool into its slot (swap and pop), so both random draws
///         and removal of a chosen ID are O(1).
contract BurnSwapPFP is ERC721, Ownable2Step, IERC4906 {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 555;

    /// @notice Number of token IDs that have never been minted.
    uint256 public unmintedCount = MAX_SUPPLY;
    /// @notice Number of tokens handed out through `mint`.
    uint256 public publicMinted;
    /// @notice Maximum number of tokens `mint` may ever hand out. Everything above this stays in the pool for swaps.
    uint256 public publicMintCap;
    /// @notice Maximum number of tokens a single wallet may receive through `mint`.
    uint256 public maxPerWallet;
    /// @notice Number of tokens destroyed through `swap`.
    uint256 public totalBurned;

    bool public mintOpen;
    bool public swapOpen;

    string public baseURI;
    string public uriSuffix = ".json";

    /// @notice Tokens each wallet has received through `mint`.
    mapping(address => uint256) public mintedBy;

    // Pool storage. 0 means "untouched", see the contract level @dev note.
    mapping(uint256 slot => uint256 tokenId) private _poolTokenAt;
    mapping(uint256 tokenId => uint256 slotPlusOne) private _poolSlotOf;

    enum TokenState {
        Unminted,
        Owned,
        Burned
    }

    event Swapped(address indexed holder, uint256 indexed burnedId, uint256 indexed newId);
    event MintOpenSet(bool open);
    event SwapOpenSet(bool open);
    event PublicMintCapSet(uint256 cap);
    event MaxPerWalletSet(uint256 max);

    error MintClosed();
    error SwapClosed();
    error ZeroQuantity();
    error ExceedsPublicMintCap();
    error ExceedsWalletLimit();
    error PoolExhausted();
    error NotTokenOwner(uint256 tokenId);
    error NotUnminted(uint256 tokenId);
    error InvalidPublicMintCap();

    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner,
        string memory baseURI_,
        uint256 publicMintCap_,
        uint256 maxPerWallet_
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        if (publicMintCap_ > MAX_SUPPLY) revert InvalidPublicMintCap();
        baseURI = baseURI_;
        publicMintCap = publicMintCap_;
        maxPerWallet = maxPerWallet_;
    }

    // ---------------------------------------------------------------------
    // Public actions
    // ---------------------------------------------------------------------

    /// @notice Mint `quantity` random tokens from the unminted pool for free.
    /// @dev    The randomness is block data mixed with the caller and pool size. It is not tamper proof:
    ///         a contract caller can revert until it draws an ID it likes. Because `swap` already lets anyone
    ///         pick a specific unminted ID, gaming the draw gains little.
    function mint(uint256 quantity) external {
        if (!mintOpen) revert MintClosed();
        if (quantity == 0) revert ZeroQuantity();
        if (publicMinted + quantity > publicMintCap) revert ExceedsPublicMintCap();
        if (mintedBy[msg.sender] + quantity > maxPerWallet) revert ExceedsWalletLimit();
        if (quantity > unmintedCount) revert PoolExhausted();

        publicMinted += quantity;
        mintedBy[msg.sender] += quantity;

        for (uint256 i; i < quantity; ++i) {
            _mint(msg.sender, _drawRandom());
        }
    }

    /// @notice Burn `burnId` (which you must own) and receive `newId`, which must still be unminted.
    function swap(uint256 burnId, uint256 newId) external {
        if (!swapOpen) revert SwapClosed();
        if (_ownerOf(burnId) != msg.sender) revert NotTokenOwner(burnId);

        _takeFromPool(newId);
        _burn(burnId);
        ++totalBurned;
        _mint(msg.sender, newId);

        emit Swapped(msg.sender, burnId, newId);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Tokens that currently exist (minted and not burned).
    function totalSupply() public view returns (uint256) {
        return MAX_SUPPLY - unmintedCount - totalBurned;
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

    /// @notice Can't go below what has already been minted or above the collection size.
    function setPublicMintCap(uint256 cap) external onlyOwner {
        if (cap < publicMinted || cap > MAX_SUPPLY) revert InvalidPublicMintCap();
        publicMintCap = cap;
        emit PublicMintCapSet(cap);
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

    /// @notice Mint specific unminted IDs to `to` (team allocation, giveaways). Ignores the mint toggle and caps.
    function airdrop(address to, uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i; i < tokenIds.length; ++i) {
            _takeFromPool(tokenIds[i]);
            _mint(to, tokenIds[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Pool internals
    // ---------------------------------------------------------------------

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

    function _takeFromPool(uint256 tokenId) private {
        if (!isUnminted(tokenId)) revert NotUnminted(tokenId);
        _removeAt(_slotOf(tokenId));
    }

    function _drawRandom() private returns (uint256) {
        uint256 seed = uint256(
            keccak256(
                abi.encode(blockhash(block.number - 1), block.prevrandao, block.timestamp, msg.sender, unmintedCount)
            )
        );
        return _removeAt(seed % unmintedCount);
    }
}
