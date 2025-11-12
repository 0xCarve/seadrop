// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct Layer {
    string name;
    uint256 primeNumber;
    uint256 numberOfTraits;
}

struct Trait {
    string name;
    string mimetype;
    uint256 occurrence;
    address dataPointer;
    bool hide;
}

struct GenerativeSettings {
    string description;
    string placeholderImage;
}

library CarveGenerativeStorage {
    struct Layout {
        mapping(uint256 => Layer) layers;
        mapping(uint256 => mapping(uint256 => Trait)) traits;
        mapping(uint256 => mapping(uint256 => uint256[])) linkedTraits;
        mapping(uint256 => bool) renderTokenOffChain;
        mapping(uint256 => uint256[]) traitOverride;
        // Fisher-Yates storage for mint-time randomness
        mapping(uint256 => uint256) tokenDataIds;
        mapping(uint256 => uint256) _availableDataIds;
        uint256 remainingDataIds;
        uint256 revealSeed;
        uint256 numberOfLayers;
        GenerativeSettings settings;
    }

    bytes32 internal constant STORAGE_SLOT =
        keccak256("carve.contracts.storage.CarveGenerative");

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}
