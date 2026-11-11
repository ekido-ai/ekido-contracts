// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ProviderRegistry
/// @notice Provider identity and hash references to off-chain GPU Passports. Holds no funds.
/// @dev A registered entry is a provider's claim. Being listed here proves nothing about its hardware.
contract ProviderRegistry is Ownable {
    struct Provider {
        bool registered;
        bytes32 metadataHash;
        bytes32 passportRoot;
    }

    address public coordinator;
    mapping(address provider => Provider) private _providers;

    event ProviderRegistered(address indexed provider, bytes32 metadataHash);
    event ProviderUpdated(address indexed provider, bytes32 metadataHash);
    event PassportAnchored(address indexed provider, bytes32 passportRoot);
    event CoordinatorUpdated(address coordinator);

    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error NotCoordinator();

    constructor(address owner_, address coordinator_) Ownable(owner_) {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
    }

    function register(bytes32 metadataHash) external {
        Provider storage p = _providers[msg.sender];
        if (p.registered) revert AlreadyRegistered();
        p.registered = true;
        p.metadataHash = metadataHash;
        emit ProviderRegistered(msg.sender, metadataHash);
    }

    function updateMetadata(bytes32 metadataHash) external {
        Provider storage p = _providers[msg.sender];
        if (!p.registered) revert NotRegistered();
        p.metadataHash = metadataHash;
        emit ProviderUpdated(msg.sender, metadataHash);
    }

    function anchorPassport(address provider, bytes32 passportRoot) external {
        if (msg.sender != coordinator) revert NotCoordinator();
        Provider storage p = _providers[provider];
        if (!p.registered) revert NotRegistered();
        p.passportRoot = passportRoot;
        emit PassportAnchored(provider, passportRoot);
    }

    function setCoordinator(address coordinator_) external onlyOwner {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorUpdated(coordinator_);
    }

    function getProvider(address provider) external view returns (Provider memory) {
        return _providers[provider];
    }
}
