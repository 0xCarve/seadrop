// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC721SeaDropUpgradeable } from "./ERC721SeaDropUpgradeable.sol";

import { LibPRNG } from "solady/utils/LibPRNG.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { DynamicBufferLib } from "solady/utils/DynamicBufferLib.sol";

import {
    CarveGenerativeStorage,
    Layer,
    Trait,
    GenerativeSettings
} from "./CarveGenerativeStorage.sol";
import {
    ERC721ContractMetadataStorage
} from "./ERC721ContractMetadataStorage.sol";

struct LinkedTraitDTO {
    uint256[] traitA;
    uint256[] traitB;
}

struct TraitDTO {
    string name;
    string mimetype;
    uint256 occurrence;
    bytes data;
    bool hide;
    bool useExistingData;
    uint256 existingDataIndex;
}

/**
 * @title  CarveGenerativeUpgradeable
 * @notice An upgradeable generative art NFT contract that integrates with SeaDrop.
 *         This contract handles trait/layer management and on-chain rendering.
 *         Minting is handled entirely through SeaDrop.
 *         Can be deployed as a clone via factory pattern.
 */
contract CarveGenerativeUpgradeable is ERC721SeaDropUpgradeable {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;
    using LibPRNG for LibPRNG.PRNG;
    using CarveGenerativeStorage for CarveGenerativeStorage.Layout;
    using ERC721ContractMetadataStorage for ERC721ContractMetadataStorage.Layout;

    event MetadataUpdate(uint256 _tokenId);

    error NotAvailable();
    error InvalidInput();
    error NotAuthorized();
    error InvalidTraitSelection(uint256 layerIndex, uint256 randomInput);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the token contract with its name, symbol,
     *         allowed SeaDrop addresses, and generative settings.
     */
    function initialize(
        string memory name,
        string memory symbol,
        address[] memory allowedSeaDrop,
        GenerativeSettings memory _settings,
        uint256 _maxSupply
    ) external initializer initializerERC721A {
        __ERC721SeaDrop_init(name, symbol, allowedSeaDrop);
        __CarveGenerative_init(_settings, _maxSupply);
    }

    function __CarveGenerative_init(
        GenerativeSettings memory _settings,
        uint256 _maxSupply
    ) internal onlyInitializing {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();
        s.settings = _settings;

        // Set max supply
        ERC721ContractMetadataStorage.layout()._maxSupply = _maxSupply;

        // Initialize Fisher-Yates dataId pool
        s.remainingDataIds = _maxSupply;

        // Auto-reveal if no placeholder is set (immediate reveal mode)
        if (bytes(_settings.placeholderImage).length == 0) {
            s.revealSeed = uint256(
                keccak256(
                    abi.encodePacked(
                        block.timestamp,
                        block.number,
                        block.difficulty,
                        tx.gasprice
                    )
                )
            );
        }
    }

    modifier whenUnsealed() {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();
        if (
            ERC721ContractMetadataStorage.layout()._maxSupply > 0 &&
            _totalMinted() >= ERC721ContractMetadataStorage.layout()._maxSupply
        ) {
            revert NotAuthorized();
        }
        _;
    }

    /**
     * @notice Override internal _mint to assign random dataIds at mint time.
     *         This hooks into both SeaDrop mints and any other mint functions.
     *
     * @param to       The address to mint to.
     * @param quantity The number of tokens to mint.
     */
    function _mint(address to, uint256 quantity) internal virtual override {
        // Check max supply before minting
        if (
            _totalMinted() + quantity >
            ERC721ContractMetadataStorage.layout()._maxSupply
        ) {
            revert MintQuantityExceedsMaxSupply(
                _totalMinted() + quantity,
                ERC721ContractMetadataStorage.layout()._maxSupply
            );
        }

        // Use _nextTokenId() to get the actual starting token ID
        // This accounts for _startTokenId() = 1
        uint256 startTokenId = _nextTokenId();

        // Always assign random dataIds at mint time using Fisher-Yates
        // Even in delayed reveal, we store them - reveal just adds rotation offset
        assignRandomDataIds(quantity, startTokenId);

        // Call parent _mint to actually mint the tokens
        super._mint(to, quantity);
    }

    function selectTrait(uint256 layerIndex, uint256 randomInput)
        internal
        view
        returns (uint256)
    {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();
        uint256 currentLowerBound = 0;
        for (uint256 i = 0; i < s.layers[layerIndex].numberOfTraits; ) {
            uint256 thisPercentage = s.traits[layerIndex][i].occurrence;
            if (
                randomInput >= currentLowerBound &&
                randomInput < currentLowerBound + thisPercentage
            ) return i;
            currentLowerBound = currentLowerBound + thisPercentage;
            unchecked {
                ++i;
            }
        }

        revert InvalidTraitSelection(layerIndex, randomInput);
    }

    /**
     * @notice Gas-efficient Fisher-Yates: gets and removes a dataId from the pool
     * @dev Only stores swapped values, not the entire array
     */
    function getAvailableDataIdAtIndex(
        uint256 indexToUse,
        uint256 currentArraySize
    ) private returns (uint256 result) {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();
        uint256 valAtIndex = s._availableDataIds[indexToUse];
        uint256 lastIndex = currentArraySize - 1;
        uint256 lastValInArray = s._availableDataIds[lastIndex];

        // Return actual value or index if unset (virtual array)
        result = valAtIndex == 0 ? indexToUse : valAtIndex;

        // Swap with last element (Fisher-Yates)
        if (indexToUse != lastIndex) {
            s._availableDataIds[indexToUse] = lastValInArray == 0
                ? lastIndex
                : lastValInArray;
        }

        // Clean up last element if it was swapped
        if (lastValInArray != 0) {
            delete s._availableDataIds[lastIndex];
        }
    }

    /**
     * @notice Assigns random dataIds to tokens at mint time using Fisher-Yates
     * @dev Called by _mint to assign dataIds before minting
     */
    function assignRandomDataIds(uint256 quantity, uint256 startTokenId)
        private
    {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        // Generate pseudo-random entropy for this batch
        uint256 batchEntropy = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.difficulty,
                    block.number,
                    blockhash(block.number - 1),
                    tx.gasprice,
                    msg.sender,
                    startTokenId
                )
            )
        );

        LibPRNG.PRNG memory prng = LibPRNG.PRNG(batchEntropy);

        // Fisher-Yates: pick random dataId from remaining pool for each token
        for (uint256 i = 0; i < quantity; i++) {
            uint256 currentSize = s.remainingDataIds - i;
            uint256 randomIndex = prng.uniform(currentSize);
            uint256 dataId = getAvailableDataIdAtIndex(
                randomIndex,
                currentSize
            );
            s.tokenDataIds[startTokenId + i] = dataId;
        }

        s.remainingDataIds -= quantity;
    }

    /**
     * @notice Get the dataId for a given tokenId
     * @dev Supports both immediate reveal and delayed reveal modes
     */
    function getTokenDataId(uint256 tokenId) public view returns (uint256) {
        if (!_exists(tokenId)) {
            revert NotAvailable();
        }

        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        // Get the stored dataId from mint time (Fisher-Yates assigned)
        uint256 storedDataId = s.tokenDataIds[tokenId];

        // Check if using immediate reveal or delayed reveal
        if (bytes(s.settings.placeholderImage).length == 0) {
            // Immediate reveal: use stored dataId as-is
            return storedDataId;
        } else {
            // Delayed reveal: apply rotation offset once revealed
            if (s.revealSeed == 0) {
                revert NotAvailable();
            }

            // Rotate all dataIds by revealSeed
            // This shifts everyone equally, maintaining Fisher-Yates randomness
            return
                (storedDataId + s.revealSeed) %
                ERC721ContractMetadataStorage.layout()._maxSupply;
        }
    }

    /**
     * @notice Get trait indices for a given dataId
     * @dev This is the core function - returns array of trait indices
     */
    function dataIdToTraits(uint256 dataId)
        public
        view
        returns (uint256[] memory)
    {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        if (s.revealSeed == 0) {
            revert NotAvailable();
        }

        // Check for trait override first
        if (s.traitOverride[dataId].length > 0) {
            return s.traitOverride[dataId];
        }

        uint256[] memory traitIndices = new uint256[](s.numberOfLayers);
        bool[] memory modifiedLayers = new bool[](s.numberOfLayers);
        uint256 traitSeed = s.revealSeed %
            ERC721ContractMetadataStorage.layout()._maxSupply;

        for (uint256 i = 0; i < s.numberOfLayers; ) {
            if (modifiedLayers[i] == false) {
                uint256 traitRangePosition = ((dataId + i + traitSeed) *
                    s.layers[i].primeNumber) %
                    ERC721ContractMetadataStorage.layout()._maxSupply;
                traitIndices[i] = selectTrait(i, traitRangePosition);
            }

            uint256 traitIndex = traitIndices[i];
            if (s.linkedTraits[i][traitIndex].length > 0) {
                uint256 linkedLayer = s.linkedTraits[i][traitIndex][0];
                traitIndices[linkedLayer] = s.linkedTraits[i][traitIndex][1];
                modifiedLayers[linkedLayer] = true;
            }
            unchecked {
                ++i;
            }
        }

        return traitIndices;
    }

    /**
     * @notice Generate SVG from trait indices
     * @dev Works directly with uint256[] - no string parsing!
     */
    function traitsToSVG(uint256[] memory traitIndices)
        internal
        view
        returns (string memory)
    {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        DynamicBufferLib.DynamicBuffer memory svgBuffer;
        svgBuffer.reserve(1024 * 64); // Pre-allocate 64KB

        svgBuffer.p(
            '<svg width="1200" height="1200" viewBox="0 0 1200 1200" version="1.2" xmlns="http://www.w3.org/2000/svg" style="background-image:url('
        );

        for (uint256 i = 0; i < s.numberOfLayers - 1; ) {
            uint256 thisTraitIndex = traitIndices[i];
            svgBuffer.p(
                abi.encodePacked(
                    "data:",
                    s.traits[i][thisTraitIndex].mimetype,
                    ";base64,",
                    Base64.encode(
                        SSTORE2.read(s.traits[i][thisTraitIndex].dataPointer)
                    ),
                    "),url("
                )
            );
            unchecked {
                ++i;
            }
        }

        uint256 lastTraitIndex = traitIndices[s.numberOfLayers - 1];
        svgBuffer.p(
            abi.encodePacked(
                "data:",
                s.traits[s.numberOfLayers - 1][lastTraitIndex].mimetype,
                ";base64,",
                Base64.encode(
                    SSTORE2.read(
                        s
                        .traits[s.numberOfLayers - 1][lastTraitIndex]
                            .dataPointer
                    )
                ),
                ');background-repeat:no-repeat;background-size:contain;background-position:center;image-rendering:-webkit-optimize-contrast;-ms-interpolation-mode:nearest-neighbor;image-rendering:-moz-crisp-edges;image-rendering:pixelated;"></svg>'
            )
        );

        return
            string(
                abi.encodePacked(
                    "data:image/svg+xml;base64,",
                    Base64.encode(svgBuffer.data)
                )
            );
    }

    /**
     * @notice Generate metadata attributes from trait indices
     * @dev Works directly with uint256[] - no string parsing!
     */
    function traitsToMetadata(uint256[] memory traitIndices)
        internal
        view
        returns (string memory)
    {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        DynamicBufferLib.DynamicBuffer memory metadataBuffer;
        metadataBuffer.reserve(1024 * 8); // Pre-allocate 8KB
        metadataBuffer.p("[");
        bool afterFirstTrait;

        for (uint256 i = 0; i < s.numberOfLayers; ) {
            uint256 thisTraitIndex = traitIndices[i];
            if (s.traits[i][thisTraitIndex].hide == false) {
                if (afterFirstTrait) {
                    metadataBuffer.p(",");
                }
                metadataBuffer.p(
                    abi.encodePacked(
                        '{"trait_type":"',
                        s.layers[i].name,
                        '","value":"',
                        s.traits[i][thisTraitIndex].name,
                        '"}'
                    )
                );
                if (afterFirstTrait == false) {
                    afterFirstTrait = true;
                }
            }

            if (i == s.numberOfLayers - 1) {
                metadataBuffer.p("]");
            }

            unchecked {
                ++i;
            }
        }

        return string(metadataBuffer.data);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        if (!_exists(tokenId)) {
            revert InvalidInput();
        }

        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        DynamicBufferLib.DynamicBuffer memory jsonBuffer;

        jsonBuffer.p(
            abi.encodePacked(
                '{"name":"',
                name(),
                " #",
                _toString(tokenId),
                '","description":"',
                s.settings.description,
                '",'
            )
        );

        if (s.revealSeed == 0) {
            jsonBuffer.p(
                abi.encodePacked('"image":"', s.settings.placeholderImage, '"}')
            );
        } else {
            // Get traits directly - no string conversion needed!
            uint256[] memory traitIndices = dataIdToTraits(
                getTokenDataId(tokenId)
            );

            if (
                bytes(ERC721ContractMetadataStorage.layout()._tokenBaseURI)
                    .length >
                0 &&
                s.renderTokenOffChain[tokenId]
            ) {
                // Off-chain rendering URL
                // External renderer can call dataIdToTraits(getTokenDataId(tokenId)) to get traits
                jsonBuffer.p(
                    abi.encodePacked(
                        '"image":"',
                        ERC721ContractMetadataStorage.layout()._tokenBaseURI,
                        _toString(tokenId),
                        "?chainId=",
                        _toString(block.chainid),
                        '",'
                    )
                );
            } else {
                // On-chain rendering - use traits directly, no parsing!
                string memory svgCode = traitsToSVG(traitIndices);

                jsonBuffer.p(abi.encodePacked('"image":"', svgCode, '",'));
            }

            // Use traits directly for metadata - no parsing!
            jsonBuffer.p(
                abi.encodePacked(
                    '"attributes":',
                    traitsToMetadata(traitIndices),
                    "}"
                )
            );
        }

        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(jsonBuffer.data)
                )
            );
    }

    function didMintEnd() public view returns (bool) {
        return
            _totalMinted() == ERC721ContractMetadataStorage.layout()._maxSupply;
    }

    function isRevealed() public view returns (bool) {
        return CarveGenerativeStorage.layout().revealSeed != 0;
    }

    function tokenIdToSVG(uint256 tokenId) public view returns (string memory) {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();
        if (s.revealSeed == 0) {
            return s.settings.placeholderImage;
        }
        // Use traits directly - no string conversion!
        return traitsToSVG(dataIdToTraits(getTokenDataId(tokenId)));
    }

    function traitDetails(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (Trait memory)
    {
        return CarveGenerativeStorage.layout().traits[layerIndex][traitIndex];
    }

    function traitData(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (bytes memory)
    {
        return
            SSTORE2.read(
                CarveGenerativeStorage
                .layout()
                .traits[layerIndex][traitIndex].dataPointer
            );
    }

    function getLinkedTraits(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (uint256[] memory)
    {
        return
            CarveGenerativeStorage.layout().linkedTraits[layerIndex][
                traitIndex
            ];
    }

    function addLayer(
        uint256 index,
        string calldata name,
        uint256 primeNumber,
        TraitDTO[] calldata _traits,
        uint256 _numberOfLayers
    ) public onlyOwner whenUnsealed {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        s.layers[index] = Layer(name, primeNumber, _traits.length);
        s.numberOfLayers = _numberOfLayers;
        for (uint256 i = 0; i < _traits.length; ) {
            address dataPointer;
            if (_traits[i].useExistingData) {
                dataPointer = s
                .traits[index][_traits[i].existingDataIndex].dataPointer;
            } else {
                dataPointer = SSTORE2.write(_traits[i].data);
            }
            s.traits[index][i] = Trait(
                _traits[i].name,
                _traits[i].mimetype,
                _traits[i].occurrence,
                dataPointer,
                _traits[i].hide
            );
            unchecked {
                ++i;
            }
        }
    }

    function addTrait(
        uint256 layerIndex,
        uint256 traitIndex,
        TraitDTO calldata _trait
    ) public onlyOwner whenUnsealed {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        address dataPointer;
        if (_trait.useExistingData) {
            dataPointer = s.traits[layerIndex][traitIndex].dataPointer;
        } else {
            dataPointer = SSTORE2.write(_trait.data);
        }
        s.traits[layerIndex][traitIndex] = Trait(
            _trait.name,
            _trait.mimetype,
            _trait.occurrence,
            dataPointer,
            _trait.hide
        );
    }

    function setLinkedTraits(LinkedTraitDTO[] calldata _linkedTraits)
        public
        onlyOwner
        whenUnsealed
    {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        for (uint256 i = 0; i < _linkedTraits.length; ) {
            s.linkedTraits[_linkedTraits[i].traitA[0]][
                _linkedTraits[i].traitA[1]
            ] = [_linkedTraits[i].traitB[0], _linkedTraits[i].traitB[1]];
            unchecked {
                ++i;
            }
        }
    }

    function setRenderOfTokenId(uint256 tokenId, bool renderOffChain) external {
        if (msg.sender != ownerOf(tokenId)) {
            revert NotAuthorized();
        }
        CarveGenerativeStorage.layout().renderTokenOffChain[
            tokenId
        ] = renderOffChain;

        emit MetadataUpdate(tokenId);
    }

    function setPlaceholderImage(string calldata placeholderImage)
        external
        onlyOwner
    {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();
        // Only allow setting placeholder if not yet revealed
        if (s.revealSeed == 0 && bytes(placeholderImage).length != 0) {
            s.settings.placeholderImage = placeholderImage;
        }
    }

    function setDescription(string calldata description) external onlyOwner {
        CarveGenerativeStorage.layout().settings.description = description;
    }

    function setRevealSeed() external onlyOwner {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        if (s.revealSeed != 0) {
            revert NotAuthorized();
        }
        s.revealSeed = uint256(
            keccak256(
                abi.encodePacked(
                    tx.gasprice,
                    block.number,
                    block.timestamp,
                    block.difficulty,
                    blockhash(block.number - 1),
                    msg.sender
                )
            )
        );

        emit BatchMetadataUpdate(
            1,
            ERC721ContractMetadataStorage.layout()._maxSupply
        );
    }

    function setTraitOverride(uint256 dataId, uint256[] calldata traitIndices)
        external
        onlyOwner
    {
        CarveGenerativeStorage.Layout storage s = CarveGenerativeStorage
            .layout();

        if (traitIndices.length != s.numberOfLayers) {
            revert InvalidInput();
        }
        s.traitOverride[dataId] = traitIndices;

        // Emit metadata update for any tokens using this dataId
        // Note: Frontend/indexers need to check which tokenIds map to this dataId
        emit BatchMetadataUpdate(
            1,
            ERC721ContractMetadataStorage.layout()._maxSupply
        );
    }

    function settings() external view returns (GenerativeSettings memory) {
        return CarveGenerativeStorage.layout().settings;
    }

    function numberOfLayers() external view returns (uint256) {
        return CarveGenerativeStorage.layout().numberOfLayers;
    }
}
